using Documenter
using CouplerMachine
using Literate

# ClimateMachine examples
const EXPERIMENTS_CM_DIR = joinpath(@__DIR__, "..", "experiments_ClimateMachine")

const OUTPUT_DIR      = joinpath(@__DIR__, "..", "docs/src/generated")

experiments = [
               "DesignTests/simple_2testcomp.jl",
               "AdvectionDiffusion/run_script_v2.jl"
              ]

for experiment in experiments
    experiment_filepath = joinpath(EXPERIMENTS_CM_DIR, experiment)
    Literate.markdown(experiment_filepath, OUTPUT_DIR, documenter=true)
end

experiment_cc_pages = [
                    "Vertical Column Heat Diffusion" => "generated/simple_2testcomp.md",
                    "Advection-diffusion on a Sphere" => "generated/run_script_v2.md",
                   ]

# ClimaCore examples
const EXPERIMENTS_CC_DIR = joinpath(@__DIR__, "..", "experiments_ClimaCore")

experiments = [
               "experiments_ClimaCore/tc1_heat-diffusion-with-slab/run.jl",
              ]

for experiment in experiments
    experiment_filepath = joinpath(EXPERIMENTS_CC_DIR, experiment)
    Literate.markdown(experiment_filepath, OUTPUT_DIR, documenter=true)
end

experiment_cc_pages = [
                    "Diffusion Column with Slab" => "generated/run.md",
                   ]



interface_pages = ["couplerstate.md", "timestepping.md", "coupledmodel.md"]


pages = Any[
    "Home" => "index.md",
    "ClimaCore Examples" => experiment_pages,
    "ClimateMachine Examples" => experiment_pages,
    "Coupler Interface" => interface_pages,
]


makedocs(
    sitename = "CouplerMachine",
    format = Documenter.HTML(),
    modules = [CouplerMachine],
    pages = pages,
)

# Documenter can also automatically deploy documentation to gh-pages.
# See "Hosting Documentation" and deploydocs() in the Documenter manual
# for more information.
deploydocs(
    repo = "<github.com/CliMA/CouplerMachine.jl.git>",
    devbranch = "main",
    push_preview = true,
)
