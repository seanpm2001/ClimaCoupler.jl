# # Moist Held-Suarez
## This script runs an idealized global circulation model, as in Thatcher and Jablonowski (2016).
## As in the dry Held-Suarez case, this case implements a Newtonian cooling scheme for radiation
## (though with modified parameters), and a Rayleigh damping scheme for dissipation.
## Additionally to the dry case, the model includes moisture with a 0-moment microphysics scheme,
## a prescribed ocean surface and a turbulent surface flux scheme.

redirect_stderr(IOContext(stderr, :stacktrace_types_limited => Ref(false)))

#=
## Configuration initialization
=#

#=
### Package Import
=#

## standard packages
import Dates
import YAML

# ## ClimaESM packages
import ClimaComms
@static pkgversion(ClimaComms) >= v"0.6" && ClimaComms.@import_required_backends
import ClimaAtmos as CA
import ClimaCore as CC

# ## Coupler specific imports
import ClimaCoupler
import ClimaCoupler:
    ConservationChecker,
    Checkpointer,
    Diagnostics,
    FieldExchanger,
    FluxCalculator,
    Interfacer,
    Regridder,
    CallbackManager,
    Utilities

pkg_dir = pkgdir(ClimaCoupler)

#=
### Helper Functions
=#

## helpers for component models
include("components/atmosphere/climaatmos.jl")

## helpers for user-specified IO
include("user_io/user_diagnostics.jl")
include("user_io/user_logging.jl")

include("user_io/io_helpers.jl")

#=
### Setup simulation parameters
Here we follow Thatcher and Jablonowski (2016).
=#

## run names
job_id = "moist_held_suarez"
coupler_output_dir = "$job_id"
const FT = Float64
restart_dir = "unspecified"
restart_t = Int(0)

## coupler simulation specific configuration
Δt_cpl = Float64(400)
t_end = "1000days"
tspan = (Float64(0.0), Float64(time_to_seconds(t_end)))
start_date = "19790301"
hourly_checkpoint = true

## namelist
config_dict = Dict(
    # general
    "FLOAT_TYPE" => string(FT),
    # file paths
    "atmos_config_file" => nothing,
    "coupler_toml_file" => nothing,
    "coupler_output_dir" => coupler_output_dir,
    "mode_name" => "",
    "job_id" => job_id,
    "atmos_config_repo" => "ClimaAtmos",
    # timestepping
    "dt" => "$(Δt_cpl)secs",
    "dt_save_to_sol" => "1days",
    "t_end" => t_end,
    "start_date" => "19790301",
    # domain
    "h_elem" => 4,
    "z_elem" => 10,
    "z_max" => 30000.0, # semi-high top
    "dz_bottom" => 300.0,
    "nh_poly" => 4,
    # output
    "dt_save_to_sol" => "1days",
    # numerics
    "apply_limiter" => false,
    "viscous_sponge" => false,
    "rayleigh_sponge" => false,
    "vert_diff" => "true",
    "hyperdiff" => "CAM_SE",
    # run
    "surface_setup" => "PrescribedSurface",
    # diagnostic (nested with period and short_name)
    "output_default_diagnostics" => false,
    "diagnostics" => [
        Dict(
            "short_name" =>
                ["mse", "lr", "mass_strf", "stab", "vt", "egr", "ua", "va", "wa", "ta", "rhoa", "pfull"],
            "period" => "6hours",
            "reduction" => "inst",
        ),
    ],
    # held-suarez specific
    "forcing" => "held_suarez", # Newtonian cooling already modified for moisture internally in Atmos
    "precip_model" => "0M",
    "moist" => "equil",
    "prognostic_surface" => "PrescribedSurfaceTemperature",
    "turb_flux_partition" => "CombinedStateFluxesMOST",
)
# TODO: may need to switch to Bulk fluxes

## merge dictionaries of command line arguments, coupler dictionary and component model dictionaries
atmos_config_dict, config_dict = get_atmos_config_dict(config_dict, job_id)
atmos_config_object = CA.AtmosConfig(atmos_config_dict)

#=
## Setup Communication Context
=#

comms_ctx = Utilities.get_comms_context(Dict("device" => "auto"))
ClimaComms.init(comms_ctx)

#=
### I/O Directory Setup
=#

dir_paths = setup_output_dirs(output_dir = coupler_output_dir, comms_ctx = comms_ctx)
ClimaComms.iamroot(comms_ctx) ? @info(config_dict) : nothing

#=
## Component Model Initialization
=#

#=
### Atmosphere
This uses the `ClimaAtmos.jl` model, with parameterization options specified in the `atmos_config_object` dictionary.
=#

## init atmos model component
atmos_sim = atmos_init(atmos_config_object);
thermo_params = get_thermo_params(atmos_sim)

#=
### Boundary Space
=#

## init a 2D boundary space at the surface
boundary_space = CC.Spaces.horizontal_space(atmos_sim.domain.face_space)

#=
### Surface Model: Prescribed Ocean
=#

# could overload surface_temperature in atmos as well, but this is more transparent
## idealized SST profile
sst_tj16(ϕ::FT; Δϕ² = FT(26)^2, ΔT = FT(29), T_min = FT(271)) = T_min + ΔT * exp(-ϕ^2 / 2Δϕ²)
ϕ = CC.Fields.coordinate_field(boundary_space).lat

ocean_sim = Interfacer.SurfaceStub((;
    T_sfc = sst_tj16.(ϕ),
    ρ_sfc = CC.Fields.zeros(boundary_space),
    z0m = FT(5e-4),
    z0b = FT(5e-4),
    beta = FT(1),
    α_direct = CC.Fields.ones(boundary_space) .* FT(1),
    α_diffuse = CC.Fields.ones(boundary_space) .* FT(1),
    area_fraction = CC.Fields.ones(boundary_space),
    phase = TD.Liquid(),
    thermo_params = thermo_params,
))

#=
## Coupler Initialization
=#

## coupler exchange fields
coupler_field_names = (
    :T_S,
    :z0m_S,
    :z0b_S,
    :ρ_sfc,
    :q_sfc,
    :surface_direct_albedo,
    :surface_diffuse_albedo,
    :beta,
    :F_turb_energy,
    :F_turb_moisture,
    :F_turb_ρτxz,
    :F_turb_ρτyz,
    :F_radiative,
    :P_liq,
    :P_snow,
    :radiative_energy_flux_toa,
    :P_net,
    :temp1,
    :temp2,
)
coupler_fields =
    NamedTuple{coupler_field_names}(ntuple(i -> CC.Fields.zeros(boundary_space), length(coupler_field_names)))
Utilities.show_memory_usage(comms_ctx)

## model simulations
model_sims = (atmos_sim = atmos_sim, ocean_sim = ocean_sim);

## dates
date0 = date = Dates.DateTime(start_date, Dates.dateformat"yyyymmdd")
dates = (; date = [date], date0 = [date0], first_day_of_month = [Dates.firstdayofmonth(date0)], new_month = [false])

#=
## Initialize Callbacks
=#

checkpoint_cb = CallbackManager.HourlyCallback(
    dt = FT(480),
    func = checkpoint_sims,
    ref_date = [dates.date[1]],
    active = hourly_checkpoint,
)
update_firstdayofmonth!_cb = CallbackManager.MonthlyCallback(
    dt = FT(1),
    func = CallbackManager.update_firstdayofmonth!,
    ref_date = [dates.first_day_of_month[1]],
    active = true,
)
callbacks = (; checkpoint = checkpoint_cb, update_firstdayofmonth! = update_firstdayofmonth!_cb)

#=
## Initialize turbulent fluxes
=#
turbulent_fluxes = nothing
if config_dict["turb_flux_partition"] == "CombinedStateFluxesMOST"
    turbulent_fluxes = FluxCalculator.CombinedStateFluxesMOST()
else
    error("turb_flux_partition must be CombinedStateFluxesMOST")
end

#=
## Initialize Coupled Simulation
=#

cs = Interfacer.CoupledSimulation{FT}(
    comms_ctx,
    dates,
    boundary_space,
    coupler_fields,
    config_dict,
    nothing, # conservation checks
    [tspan[1], tspan[2]],
    atmos_sim.integrator.t,
    Δt_cpl,
    (; land = zeros(boundary_space), ocean = ones(boundary_space), ice = zeros(boundary_space)),
    model_sims,
    (;), # mode_specifics
    (), # coupler diagnostics
    callbacks,
    dir_paths,
    turbulent_fluxes,
    thermo_params,
);

#=
## Restart component model states if specified in the config_dict
=#

if restart_dir !== "unspecified"
    for sim in cs.model_sims
        if Checkpointer.get_model_prog_state(sim) !== nothing
            Checkpointer.restart_model_state!(sim, comms_ctx, restart_t; input_dir = restart_dir)
        end
    end
end

#=
## Initialize Component Model Exchange
=#

# 1.surface density (`ρ_sfc`): calculated by the coupler by adiabatically extrapolating atmospheric thermal state to the surface.
# For this, we need to import surface and atmospheric fields. The model sims are then updated with the new surface density.
FieldExchanger.import_combined_surface_fields!(cs.fields, cs.model_sims, cs.turbulent_fluxes)
FieldExchanger.import_atmos_fields!(cs.fields, cs.model_sims, cs.boundary_space, cs.turbulent_fluxes)
FieldExchanger.update_model_sims!(cs.model_sims, cs.fields, cs.turbulent_fluxes)

# 2.surface vapor specific humidity (`q_sfc`): step surface models with the new surface density to calculate their respective `q_sfc` internally
Interfacer.step!(ocean_sim, Δt_cpl)

# 3.turbulent fluxes
## import the new surface properties into the coupler (note the atmos state was also imported in step 3.)
FieldExchanger.import_combined_surface_fields!(cs.fields, cs.model_sims, cs.turbulent_fluxes) # i.e. T_sfc, albedo, z0, beta, q_sfc
## calculate turbulent fluxes inside the atmos cache based on the combined surface state in each grid box
FluxCalculator.combined_turbulent_fluxes!(cs.model_sims, cs.fields, cs.turbulent_fluxes) # this updates the atmos thermo state, sfc_ts

# 4.reinitialize models + radiative flux: prognostic states and time are set to their initial conditions.
FieldExchanger.reinit_model_sims!(cs.model_sims)

# 5.update all fluxes: coupler re-imports updated atmos fluxes
FieldExchanger.import_atmos_fields!(cs.fields, cs.model_sims, cs.boundary_space, cs.turbulent_fluxes)
FieldExchanger.update_model_sims!(cs.model_sims, cs.fields, cs.turbulent_fluxes)

#=
## Coupling Loop
=#

function solve_coupler!(cs)
    (; model_sims, Δt_cpl, tspan, comms_ctx) = cs

    ClimaComms.iamroot(comms_ctx) && @info("Starting coupling loop")
    ## step in time
    for t in ((tspan[begin] + Δt_cpl):Δt_cpl:tspan[end])

        cs.dates.date[1] = Interfacer.current_date(cs, t)

        ## print date on the first of month
        if cs.dates.date[1] >= cs.dates.first_day_of_month[1]
            ClimaComms.iamroot(comms_ctx) && @show(cs.dates.date[1])
        end
        ClimaComms.barrier(comms_ctx)

        ## run component models sequentially for one coupling timestep (Δt_cpl)
        FieldExchanger.update_model_sims!(cs.model_sims, cs.fields, cs.turbulent_fluxes)

        ## step sims
        FieldExchanger.step_model_sims!(cs.model_sims, t)

        ## exchange combined fields and (if specified) calculate fluxes using combined states
        FieldExchanger.import_combined_surface_fields!(cs.fields, cs.model_sims, cs.turbulent_fluxes) # i.e. T_sfc, surface_albedo, z0, beta
        FluxCalculator.combined_turbulent_fluxes!(cs.model_sims, cs.fields, cs.turbulent_fluxes)

        FieldExchanger.import_atmos_fields!(cs.fields, cs.model_sims, cs.boundary_space, cs.turbulent_fluxes)

        ## callback to update the fist day of month
        CallbackManager.trigger_callback!(cs.callbacks.update_firstdayofmonth!, cs.dates.date[1])

        ## callback to checkpoint model state
        CallbackManager.trigger_callback!(cs.callbacks.checkpoint, cs.dates.date[1])

    end

    return nothing
end

## run the coupled simulation
solve_coupler!(cs);
