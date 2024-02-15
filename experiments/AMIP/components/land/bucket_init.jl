# slab_rhs!
using ClimaCore
import ClimaTimeSteppers as CTS
import Thermodynamics as TD
using Dates: DateTime
using ClimaComms: AbstractCommsContext
import CLIMAParameters

import ClimaLand
using ClimaLand.Bucket: BucketModel, BucketModelParameters, AbstractAtmosphericDrivers, AbstractRadiativeDrivers
import ClimaLand.Bucket: BulkAlbedoTemporal, BulkAlbedoStatic, BulkAlbedoFunction
using ClimaLand:
    make_exp_tendency,
    initialize,
    make_set_initial_cache,
    surface_evaporative_scaling,
    CoupledRadiativeFluxes,
    CoupledAtmosphere
import ClimaLand.Parameters as LP


import ClimaCoupler.Interfacer: LandModelSimulation, get_field, update_field!, name
import ClimaCoupler.FieldExchanger: step!, reinit!
import ClimaCoupler.FluxCalculator: update_turbulent_fluxes_point!, surface_thermo_state

"""
    BucketSimulation{M, Y, D, I}

The bucket model simulation object.
"""
struct BucketSimulation{M, Y, D, I, A} <: LandModelSimulation
    model::M
    Y_init::Y
    domain::D
    integrator::I
    area_fraction::A
end
name(::BucketSimulation) = "BucketSimulation"

include("./bucket_utils.jl")

"""
    temp_anomaly_aquaplanet(coord)

Introduce a temperature IC anomaly for the aquaplanet case.
The values for this case follow the moist Held-Suarez setup of Thatcher &
Jablonowski (2016, eq. 6), consistent with ClimaAtmos aquaplanet.
"""
temp_anomaly_aquaplanet(coord) = 29 * exp(-coord.lat^2 / (2 * 26^2))

"""
    temp_anomaly_amip(coord)

Introduce a temperature IC anomaly for the AMIP case.
The values used in this case have been tuned to align with observed temperature
and result in stable simulations.
"""
temp_anomaly_amip(coord) = 40 * cosd(coord.lat)^4

"""
    bucket_init

Initializes the bucket model variables.
"""
function bucket_init(
    ::Type{FT},
    tspan::Tuple{Float64, Float64},
    config::String,
    albedo_type::String,
    land_temperature_anomaly::String,
    regrid_dirpath::String;
    space,
    dt::Float64,
    saveat::Float64,
    area_fraction,
    stepper = CTS.RK4(),
    date_ref::DateTime,
    t_start::Float64,
) where {FT}
    if config != "sphere"
        println(
            "Currently only spherical shell domains are supported; single column set-up will be addressed in future PR.",
        )
        @assert config == "sphere"
    end

    earth_param_set = LP.LandParameters(FT)

    α_snow = FT(0.8) # snow albedo
    if albedo_type == "map_static" # Read in albedo from static data file (default type)
        # By default, this uses a file containing bareground albedo without a time component. Snow albedo is specified separately.
        albedo = BulkAlbedoStatic{FT}(regrid_dirpath, space, α_snow = α_snow)
    elseif albedo_type == "map_temporal" # Read in albedo from data file containing data over time
        # By default, this uses a file containing linearly-interpolated monthly data of total albedo, generated by CESM2's land model (CLM).
        albedo = BulkAlbedoTemporal{FT}(regrid_dirpath, date_ref, t_start, space)
    elseif albedo_type == "function" # Use prescribed function of lat/lon for surface albedo
        function α_bareground(coordinate_point)
            (; lat, long) = coordinate_point
            return typeof(lat)(0.38)
        end
        albedo = BulkAlbedoFunction{FT}(α_snow, α_bareground, space)
    else
        error("invalid albedo type $albedo_type")
    end

    σS_c = FT(0.2)
    W_f = FT(10)
    d_soil = FT(3.5) # soil depth
    z_0m = FT(1e-3) # roughness length for momentum over smooth bare soil
    z_0b = FT(1e-3) # roughness length for tracers over smooth bare soil
    κ_soil = FT(0.7)
    ρc_soil = FT(2e8)
    t_crit = FT(dt) # This is the timescale on which snow exponentially damps to zero, in the case where all
    # the snow would melt in time t_crit. It prevents us from having to specially time step in cases where
    # all the snow melts in a single timestep.
    params = BucketModelParameters(κ_soil, ρc_soil, albedo, σS_c, W_f, z_0m, z_0b, t_crit, earth_param_set)
    n_vertical_elements = 7
    # Note that this does not take into account topography of the surface, which is OK for this land model.
    # But it must be taken into account when computing surface fluxes, for Δz.
    domain = make_land_domain(space, (-d_soil, FT(0.0)), n_vertical_elements)
    args = (params, CoupledAtmosphere{FT}(), CoupledRadiativeFluxes{FT}(), domain)
    model = BucketModel{FT, typeof.(args)...}(args...)

    # Initial conditions with no moisture
    Y, p, coords = initialize(model)

    # Get temperature anomaly function
    T_functions = Dict("aquaplanet" => temp_anomaly_aquaplanet, "amip" => temp_anomaly_amip)
    haskey(T_functions, land_temperature_anomaly) ||
        error("land temp anomaly function $land_temperature_anomaly not supported")
    temp_anomaly = T_functions[land_temperature_anomaly]

    # Set temperature IC including anomaly, based on atmospheric setup
    T_sfc_0 = FT(271.0)
    @. Y.bucket.T = T_sfc_0 + temp_anomaly(coords.subsurface)

    Y.bucket.W .= 6.5
    Y.bucket.Ws .= 0.0
    Y.bucket.σS .= 0.0
    @show axes(Y.bucket.σS) == space
    @show space.topology
    # Set initial aux variable values
    set_initial_cache! = make_set_initial_cache(model)
    set_initial_cache!(p, Y, tspan[1])

    exp_tendency! = make_exp_tendency(model)
    ode_algo = CTS.ExplicitAlgorithm(stepper)
    bucket_ode_function = CTS.ClimaODEFunction(T_exp! = exp_tendency!, dss! = ClimaLand.dss!)
    prob = ODEProblem(bucket_ode_function, Y, tspan, p)
    integrator = init(prob, ode_algo; dt = dt, saveat = saveat, adaptive = false)

    sim = BucketSimulation(model, Y, (; domain = domain, soil_depth = d_soil), integrator, area_fraction)

    # DSS state to ensure we have continuous fields
    dss_state!(sim)
    return sim
end
