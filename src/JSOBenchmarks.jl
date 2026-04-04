module JSOBenchmarks

# stdlib modules
using Pkg

# Third-party modules
using DataFrames
using DocStringExtensions
using Git
using GitHub
using JLD2
using JSON
using PkgBenchmark
using Plots
using StatsPlots

# JSO modules
using SolverBenchmark

export run_benchmarks
export profile_solvers_from_pkgbmark
export create_gist_from_json_dict, create_gist_from_json_file
export update_gist_from_json_dict, update_gist_from_json_file
export write_md

const git = Git.git()

# use: run_benchmarks.jl repository_name gist_url
#
# example: run_benchmarks.jl LimitedLDLFactorizations.jl https://gist.github.com/dpo/911c1e3b9d341d5cddb61deb578d8ed3

"""
Run benchmarks from a repository, compare against a reference branch and post results to a gist.

$(TYPEDSIGNATURES)

This method is intended to be called from a pull request.
"""
function run_benchmarks(
  repo_name::AbstractString,
  bmark_dir::AbstractString;
  reference_branch::AbstractString = "main",
  gist_url::Union{AbstractString, Nothing} = nothing,
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

  # Begin benchmarks
  # NB: benchmarkpkg will run benchmarks/benchmarks.jl by default

  @info "benchmarking this_commit" repo_name
  this_commit = benchmarkpkg(repo_name)  # current state of repository
  local reference
  local judgement
  if is_git
    @info "benchmarking reference branch" reference_branch
    reference = benchmarkpkg(repo_name, reference_branch)
    judgement = judge(this_commit, reference)
  end

  @info "exporting results to markdown"
  this_commit_stats = bmark_results_to_dataframes(this_commit)
  export_markdown("$(bmarkname).md", this_commit)
  local reference_stats
  local judgement_stats
  if is_git
    reference_stats = bmark_results_to_dataframes(reference)
    export_markdown("reference.md", reference)
    judgement_stats = judgement_results_to_dataframes(judgement)
    export_markdown("judgement_$(bmarkname).md", judgement)
  end

  # extract stats for each benchmark to plot profiles
  # files_dict will be part of json_dict below
  files_dict = Dict{String, Any}()
  svgs = String[]
  if is_git
    @info "saving data, preparing performance profiles"
    for k ∈ keys(judgement_stats)
      # k is the name of a benchmark suite
      k_stats = Dict{Symbol, DataFrame}(
        :this_commit => this_commit_stats[k],
        :reference => reference_stats[k],
      )

      # save benchmark data to jld2 file
      save_stats(k_stats, "$(bmarkname)_vs_reference_$(k).jld2", force = true)

      # plot absolute metrics
      this_commit_k = this_commit_stats[k]
      reference_k = reference_stats[k]
      names = string.(this_commit_k[!, :name])
      for property ∈ propertynames(this_commit_k)
        property == :name && continue
        commit_values = this_commit_k[!, property]
        reference_values = reference_k[!, property]
        groupedbar(
          names,
          [commit_values reference_values],
          title = string(property),
          label = ["commit" "reference"],
          bar_width = 0.7,
          bar_position = :dodge,
          xrotation = 45,
          tickfontsize = 4,
        )
        fname = "this_commit_vs_reference_$(k)_$(property)"
        savefig("$(fname).svg")  # for the artifacts
        savefig("$(fname).png")  # for the markdown summary
        push!(svgs, "$(fname).svg")
        k_svgfile = open("$(fname).svg", "r") do fd
          readlines(fd)
        end
        files_dict["$(fname).svg"] = Dict{String, Any}("content" => join(k_svgfile))
      end

      _ = profile_solvers_from_pkgbmark(k_stats)
      fname = "profiles_this_commit_vs_reference_$(k)"
      savefig("$(fname).svg")  # for the artifact"
      savefig("$(fname).png")  # for the markdown summary
      push!(svgs, "$(fname).svg")
      # read contents of svg file to add to gist
      k_svgfile = open("$(fname).svg", "r") do fd
        readlines(fd)
      end
      files_dict["$(fname).svg"] = Dict{String, Any}("content" => join(k_svgfile))
    end
  end

  files_dict["this_commit.md"] =
    Dict{String, Any}("content" => "$(sprint(export_markdown, this_commit))")
  if is_git
    files_dict["reference.md"] =
      Dict{String, Any}("content" => "$(sprint(export_markdown, reference))")
    files_dict["judgement.md"] =
      Dict{String, Any}("content" => "$(sprint(export_markdown, judgement))")
  end

  if is_git
    # save judgement data to jld2 file
    jldopen("$(bmarkname)_vs_reference_judgement.jld2", "w") do file
      file["jstats"] = judgement_stats
    end
  end

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

  @info "preparing simple Markdown report"
  is_git && write_simple_md_report(
    "bmark_$(bmarkname).md",
    this_commit,
    reference,
    judgement,
    update_gist ? gist_url : new_gist_url,
    svgs,
  )

  @info "finished"
  return nothing
end

# Utility functions

"""
Produce performance profiles from PkgBenchmark results.

$(TYPEDSIGNATURES)

The profiles produced are with respect to time, memory, garbage collection time and allocations.
"""
function profile_solvers_from_pkgbmark(stats::Dict{Symbol, DataFrame})
  # guard against zero gctimes
  costs =
    [df -> df[!, :time], df -> df[!, :memory], df -> df[!, :gctime] .+ 1, df -> df[!, :allocations]]
  profile_solvers(stats, costs, ["time", "memory", "gctime+1", "allocations"])
end

"""
Create a new gist from a JSON dictionary.

$(TYPEDSIGNATURES)

Return the new gist.
"""
function create_gist_from_json_dict(json_dict)
  myauth = GitHub.authenticate(ENV["GITHUB_AUTH"])
  posted_gist = create_gist(params = json_dict, auth = myauth)
  return posted_gist
end

"""
Read a JSON dictionary from file and use it to create a new gist.

$(TYPEDSIGNATURES)

Return the value of `create_gist_from_json_dict()`.
"""
function create_gist_from_json_file(gistfile = "gist.json")
  json_dict = begin
    open(gistfile, "r") do f
      return JSON.parse(f)
    end
  end
  return create_gist_from_json_dict(json_dict)
end

"""
Update an existing gist from a JSON dictionary.

$(TYPEDSIGNATURES)

Return the value of `GitHub.edit_gist()`.
"""
function update_gist_from_json_dict(gist_id, json_dict)
  myauth = GitHub.authenticate(ENV["GITHUB_AUTH"])
  existing_gist = gist(gist_id)
  return edit_gist(existing_gist, params = json_dict, auth = myauth)
end

"""
Read a JSON dictionary from file and use it to update an existing gist.

$(TYPEDSIGNATURES)

Return the value of `update_gist_from_json_dict()`.
"""
function update_gist_from_json_file(gist_id, gistfile = "gist.json")
  json_dict = begin
    open(gistfile, "r") do f
      return JSON.parse(f)
    end
  end
  return update_gist_from_json_dict(gist_id, json_dict)
end

function write_md(io::IO, title::AbstractString, results)
  println(io, "<details>")
  println(io, "<summary>$(title)</summary>")
  println(io, "<br>\n")
  println(io, sprint(export_markdown, results))
  println(io, "</details>")
end

function write_md_svgs(io::IO, title::AbstractString, gist_url, svgs)
  println(io, "<details>")
  println(io, "<summary>$(title)</summary>")
  for svg ∈ svgs
    println(io, "<br>\n")
    println(io, "[$(svg)]($(gist_url)/raw/$(svg)?sanitize=true)")
  end
  println(io, "</details>")
end

"""
Write a simple Markdown report to file that can be used to comment a pull request.

$(TYPEDSIGNATURES)
"""
function write_simple_md_report(
  fname::AbstractString,
  this_commit,
  reference,
  judgement,
  gist_url,
  svgs,
)
  # simpler markdown summary to post in pull request
  open(fname, "w") do f
    println(f, "Gist: $(gist_url)\n")
    println(f, "Full results stored as artifacts\n")
    write_md_svgs(f, "Overview", gist_url, svgs)
    write_md(f, "Judgement", judgement)
    println(f, "<br>")
    write_md(f, "this_commit", this_commit)
    println(f, "<br>")
    write_md(f, "Reference", reference)
  end
end

end # module JSOBenchmarks
