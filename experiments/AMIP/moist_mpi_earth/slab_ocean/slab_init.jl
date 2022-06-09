# slab_rhs!
using ClimaCore

# ocean parameters
struct OceanSlabParameters# <: CLIMAParameters.AbstractEarthParameterSet{F} 
    h::FT
    ρ::FT
    c::FT
    T_init::FT
    z0m::FT
    z0b::FT
    α::FT
end

# init simulation
function slab_ocean_space_init(::Type{FT}, space, p) where {FT}

    coords = ClimaCore.Fields.coordinate_field(space)

    # initial condition
    T_sfc = map(coords) do coord
        T_sfc_0 = FT(p.T_init) #- FT(275) # close to the average of T_1 in atmos
        anom_ampl = FT(0)
        radlat = coord.lat / FT(180) * pi
        lat_0 = FT(60) / FT(180) * pi
        lon_0 = FT(-90) / FT(180) * pi
        radlon = coord.long / FT(180) * pi
        stdev = FT(5) / FT(180) * pi
        anom = anom_ampl * exp(-((radlat - lat_0)^2 / 2stdev^2 + (radlon - lon_0)^2 / 2stdev^2))
        T_sfc = T_sfc_0 + anom
    end

    # prognostic variable
    Y = ClimaCore.Fields.FieldVector(T_sfc = T_sfc)

    return Y, space
end

# ode
function slab_ocean_rhs!(dY, Y, Ya, t)
    """
    Slab ocean:
    ∂_t T_sfc = F_aero + G
    """
    p, F_aero, F_rad = Ya
    dY.T_sfc .= @. (F_aero + F_rad) / (p.h * p.ρ * p.c)
end

function slab_ocean_init(
    ::Type{FT},
    tspan;
    stepper = Euler(),
    nelements = 6,
    npolynomial = 4,
    dt = 0.02,
    saveat = 1.0e10,
    space = nothing,
) where {FT}

    params = OceanSlabParameters(FT(20), FT(1500.0), FT(800.0), FT(280.0), FT(1e-3), FT(1e-5), FT(0.06))

    Y, space = slab_ocean_space_init(FT, space, params)
    Ya = (params = params, F_aero = ClimaCore.Fields.zeros(space), F_rad = ClimaCore.Fields.zeros(space))
    problem = OrdinaryDiffEq.ODEProblem(slab_ocean_rhs!, Y, tspan, Ya)
    integrator = OrdinaryDiffEq.init(problem, stepper, dt = dt, saveat = saveat)

    SlabSimulation(params, Y, space, integrator)
end
