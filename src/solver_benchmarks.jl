"""
    run_solver_benchmarks(repo_name, bmark_dir; reference_branch="main", gist_url=nothing, script="benchmarks.jl")

Run a benchmark script, based on the SolverBenchmarks.jl package, for a Julia repository.

This function executes a benchmark script (`script`) in the specified benchmark directory (`bmark_dir`) for 
the current state of the repository containing `repo_name`. 
The output of the script should be a result of `BenchmarkSolver.bmark_solvers`. If the repository is a Git repository, the 
benchmarks are run on the current commit and optionally compared to a reference branch (default `"main"`). 
The results are saved as `.jld2` files, performance profile plots and summary tables are generated. 
Optionally, results can be uploaded or updated in a GitHub Gist (`gist_url`).

# Arguments

- `repo_name::AbstractString`  
  The name of the Julia package repository being benchmarked.

- `bmark_dir::AbstractString`  
  Path to the directory containing the benchmark scripts. This is usually a `benchmarks/` folder 
  inside the repository.

# Keyword Arguments

- `reference_branch::AbstractString = "main"`  
  The Git branch used as a reference for comparison in plots and tables.

- `gist_url::Union{AbstractString, Nothing} = nothing`  
  If provided, the function updates the existing Gist at this URL. Otherwise, a new Gist is created.

- `script::AbstractString = "benchmarks.jl"`  
  The Julia script in `bmark_dir` that runs the benchmark suite. Must return a `Dict{Symbol, DataFrame}` 
  as produced by `BenchmarkSolver.bmark_solvers`.

# Output

Returns a `String` containing the URL of the Gist with benchmark results. If `gist_url` was provided, 
the existing Gist is updated; otherwise, a new Gist URL is returned.

# Plots and Tables values

In order to compare specific outputs from the benchmark results, the `script` can override the functions
    JSOBenchmarks.solver_benchmark_profile_values()
    JSOBenchmarks.solver_benchmark_table_values()
to specify which columns from the DataFrames should be used for the performance profiles and summary tables, respectively.
Both should return an array of pairs, where the first element is a `Symbol` representing the column name in the DataFrame
and the second element is a `String` representing the label to be used in the plots and tables.

# Notes

- This function is mostly expected to be called from a GitHub workflow.
- Please refer to `SolverBenchmarks.bmark_solvers` for more information on how to write the benchmark script.
"""
function run_solver_benchmarks(
  repo_name::AbstractString,
  bmark_dir::AbstractString;
  reference_branch::AbstractString = "main",
  gist_url::Union{AbstractString, Nothing} = nothing,
  script = "benchmarks.jl",
)

  update_gist = gist_url !== nothing
  is_git = isdir(joinpath(bmark_dir, "..", ".git"))
  @info "" is_git update_gist

  local gist_id
  if update_gist
    gist_id = split(gist_url, "/")[end]
    @info "" gist_id
  end

  # if we are running these benchmarks from the git repository
  # we want to develop the package instead of using the release
  if is_git
    Pkg.develop(PackageSpec(path = joinpath(bmark_dir, "..")))
  else
    Pkg.activate(bmark_dir)
  end
  Pkg.instantiate()

  # name the benchmark after the repo or the sha of HEAD
  bmarkname = is_git ? readchomp(`$git rev-parse HEAD`) : lowercase(repo_name)
  @info "" bmarkname

  # Run the benchmark script on this commit
  this_commit = Base.include(Main, joinpath(bmark_dir, script))
  @assert this_commit isa Dict{Symbol, DataFrame} "Expected the benchmark script to return a Dict{Symbol, DataFrame}, but got $(typeof(this_commit)). Make sure your benchmark script returns a dict resulting from BenchmarkSolver.bmark_solvers function"
  @save "$(bmarkname)_solver_benchmarks_this_commit.jld2" this_commit

  # Run the benchmark script on the reference branch
  local reference
  if is_git
    repo_dir = joinpath(bmark_dir, "..")
    repo = LibGit2.GitRepo(repo_dir)
    reference = _withcommit(joinpath(bmark_dir, script), repo, reference_branch, bmarkname = bmarkname)
  end

  # Plotting and tables
  local profile_values, table_values

  profile_values = Base.invokelatest(solver_benchmark_profile_values)
  table_values = Base.invokelatest(solver_benchmark_table_values)

  files_dict = Dict{String, Any}()
  svgs = String[]

  solved(df) = (df.status .== :first_order)
  costs = [df -> .!solved(df) * Inf + getproperty(df, value[1]) for value in profile_values]
  costnames = [value[2] for value in profile_values]

  stats_columns = [value[1] for value in table_values]

  tables = "# Solver Benchmarks Tables \n\n"
  if is_git
    for key in keys(this_commit)
      if haskey(reference, key)
        @info "Plotting $key"
        stats_subset = Dict(:this_commit => this_commit[key], :reference => reference[key])
        p = profile_solvers(stats_subset, costs, costnames, xlabel = "", ylabel = "")
        fname = "this_commit_vs_reference_$(key)"
        savefig("$(fname).svg")
        savefig("profiles_$(fname).pdf")
        push!(svgs, "$(fname).svg")
        content = read("$(fname).svg", String)
        files_dict["$(fname).svg"] = Dict("content" => content)

        @info "Creating tables for $key"
        tables *= "\n## This commit vs reference: $(key)\n\n"
        tables *= "### This commit\n\n\n"
        tables *= sprint(io -> pretty_stats(io, this_commit[key][!, stats_columns], hdr_override = Dict(table_values), tf=tf_markdown))
        open("this_commit_$(key).tex", "w") do io
          pretty_latex_stats(io, this_commit[key][!, stats_columns], hdr_override = Dict(table_values))
        end
        tables *= "\n\n### Reference\n\n\n"
        tables *= sprint(io -> pretty_stats(io, reference[key][!, stats_columns], hdr_override = Dict(table_values), tf=tf_markdown))
        open("reference_$(key).tex", "w") do io
          pretty_latex_stats(io, reference[key][!, stats_columns], hdr_override = Dict(table_values))
        end
      else
        @warn "$(reference_branch) branch benchmarks do not run the solver $key. Please update the benchmark solver list in a separate PR and rebase."
      end
    end
  end

  files_dict["tables.md"] = Dict("content" => tables)

  @info "creating or updating gist"
  # json description of gist
  json_dict = Dict{String, Any}(
    "description" => "$(repo_name) repository benchmark",
    "public" => true,
    "files" => files_dict,
  )

  if update_gist
    json_dict["gist_id"] = gist_id
  end

  gist_json = "$(bmarkname).json"
  open(gist_json, "w") do f
    JSON.print(f, json_dict)
  end

  local new_gist_url
  if update_gist
    update_gist_from_json_dict(gist_id, json_dict)
  else
    new_gist = create_gist_from_json_dict(json_dict)
    new_gist_url = string(new_gist.html_url)
  end

  # Update markdown report
  if is_git
    fname = "bmark_$(bmarkname).md"
    open(fname, "a") do f
      write_md_svgs(f, "SolverBenchmark Profiles", gist_url, svgs)
    end
  end
  
  @info "finished"
  return update_gist ? gist_url : new_gist_url
end

function solver_benchmark_profile_values()
  return [(:elapsed_time, "CPU Time"), (:neval_obj, "# Objective Evals"), (:neval_grad, "# Gradient Evals")]
end

function solver_benchmark_table_values()
  return [(:name, "Name"), (:objective, "f(x)"), (:elapsed_time, "Time")]
end

# Runs a script at a commit on a repo and afterwards goes back
# to the original commit / branch.
# This code is based on https://github.com/JuliaCI/PkgBenchmark.jl/blob/master/src/util.jl
function _withcommit(script, repo, commit; bmarkname = "")
  original_commit = string(LibGit2.GitHash(LibGit2.GitObject(repo, "HEAD")))
  local result
  LibGit2.transact(repo) do r
    branch = try LibGit2.branch(r) catch err; nothing end
    try
      LibGit2.checkout!(r, _shastring(r, commit))

      env_to_use = dirname(Pkg.Types.Context().env.project_file) 
      save_file_name = "$(bmarkname)_solver_benchmarks_reference"
      exec_str =
        """
        using JSOBenchmarks
        JSOBenchmarks._run_local($(repr(script)), "$(save_file_name)")
        """
      run(`$(Base.julia_cmd()) --project=$env_to_use --depwarn=no -e $exec_str`)

      result = load("$(save_file_name).jld2")["result"]

      @assert result isa Dict{Symbol, DataFrame} "Expected the benchmark script to return a Dict{Symbol, DataFrame}, but got $(typeof(result)). Make sure your benchmark script returns a dict resulting from BenchmarkSolver.bmark_solvers function"
    catch err
        rethrow(err)
    finally
      if branch !== nothing
        LibGit2.branch!(r, branch)
      else
        LibGit2.checkout!(r, original_commit)
      end
    end
  end
  return result
end

function _run_local(script, save_file_name)
  result = Base.include(Main, script)
  @save "$(save_file_name).jld2" result
end

function _shastring(r::LibGit2.GitRepo, targetname)
  branch = LibGit2.lookup_branch(r, targetname)
  branch = branch === nothing ? LibGit2.lookup_branch(r, targetname, true) : branch # Search remote as well if not found locally.
  branch = branch === nothing ? LibGit2.lookup_branch(r, "origin/$(targetname)") : branch
  branch = branch === nothing ? LibGit2.lookup_branch(r, "origin/$(targetname)", true) : branch # Search remote as well if not found locally.
  @assert branch !== nothing "Branch $(targetname) not found in repository."
  return string(LibGit2.GitHash(LibGit2.GitObject(r, LibGit2.name(branch))))
end