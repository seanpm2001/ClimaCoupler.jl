using ClimaCore.Geometry: ⊗
using ClimaCore: Spaces, Fields
using ClimaCore.Utilities: half, PlusHalf
using ClimaCoupler: Regridder
# import ClimaAtmos: get_surface_fluxes_point!

# Interface for component models
# update_turbulent_fluxes_point!(sim, fields, colidx) = nothing
# update_calculated_fluxes!(sim, fields) = nothing

# update_collected_atmos_fluxes!(sim, fields) = nothing
# get_temperature_point(sim, colidx) = nothing
# get_humidity_point(sim, colidx) = nothing
# get_z0m_point(sim, colidx) = nothing
# get_z0b_point(sim, colidx) = nothing
# get_beta_point(sim, colidx) = nothing
# get_albedo_point(sim, colidx) = nothing
# get_heat_transfer_coefficient_point(sim, colidx) = nothing
# get_drag_transfer_coefficient_point(sim, colidx) = nothing

# get_temperature(sim) = nothing
# get_humidity(sim) = nothing
# get_z0m(sim) = nothing
# get_z0b(sim) = nothing
# get_beta(sim) = nothing
# get_albedo(sim) = nothing
# get_area_fraction(sim) = nothing


abstract type ComponentModelSimulation end
abstract type AtmosModelSimulation <: ComponentModelSimulation end
abstract type SurfaceModelSimulation <: ComponentModelSimulation end

abstract type AbstractSurfaceFluxScheme end
struct BulkScheme <: AbstractSurfaceFluxScheme end
struct MoninObukhovScheme <: AbstractSurfaceFluxScheme end
# get_surface_scheme(_) = MoninObukhovScheme()

get_field(sim::ComponentModelSimulation, val::Val, colidx::Fields.ColumnIndex) = get_field(sim, val)[colidx]

struct Warning
    message::String
end

function reinit!(sim)
    warning = Warning("undefined `reinit!` for " * name(sim) * ": skipping")
    @warn(warning.message, maxlog=10)
    return warning
end

function update!(sim, val::Val, _...)
    warning = Warning("undefined `update!` for $val in " * name(sim) * ": skipping")
    @warn(warning.message, maxlog=10)
    return warning
end
name(sim) = "stub  simulation"

# struct StubSimulation{F, P, Y, D, I, A} <: ComponentModelSimulation
#     FT::F
#     params::P
#     Y_init::Y
#     domain::D
#     integrator::I
#     area_fraction::A
# end
# function StubSimulation(FT; params= (;), Y_init = (;), domain = (;), integrator = (;), area_fraction = (;))
#     StubSimulation(FT, params, Y_init, domain,integratorm, area_fraction)
# end

# name(::SlabOceanSimulation) = "StubSimulation"

# end intrface
"""
    calculate_and_send_turbulent_fluxes!(cs::)

Calculates surface fluxes using adapter function `get_surface_fluxes_point!`
from ClimaAtmos that calls `SurfaceFluxes.jl`. The coupler updates in
atmos model cache fluxes at each coupling timestep.

- TODO: generalize interface for regridding and take land state out of atmos's integrator.p

The current setup calculates the aerodynamic fluxes in the coupler and assumes no regridding is needed.
(NB: Radiation surface fluxes are calculated by the atmosphere.)

"""

function calculate_and_send_turbulent_fluxes!(model_sims, fields, boundary_space, surface_scheme, thermo_params)

    atmos_sim = model_sims.atmos_sim;
    csf = fields
    FT = eltype(csf[1])

    # reset coupler fields (TODO: add flux accumulation)
    csf.F_ρτxz .*= FT(0)
    csf.F_ρτyz .*= FT(0)
    csf.F_shf .*= FT(0)
    csf.F_lhf .*= FT(0)
    csf.F_evap .*= FT(0)

    for sim in model_sims
        if sim isa SurfaceModelSimulation
            extra_aux_update(sim, thermo_params, get_field(atmos_sim, Val(:thermo_state_int)) )
        end
    end

    # iterate over all columns (when regridding, this will need to change)
    Fields.bycolumn(boundary_space) do colidx
        # atmos state of center level 1
        z_int = get_field(atmos_sim, Val(:height_int), colidx)
        uₕ_int = get_field(atmos_sim, Val(:uv_int_point), colidx)
        thermo_state_int = get_field(atmos_sim, Val(:thermo_state_int), colidx)

        z_sfc = get_field(atmos_sim, Val(:height_sfc), colidx)

        for sim in model_sims
            # iterate over all surface models with non-zero area fractions
            if sim isa SurfaceModelSimulation
                area_fraction = get_field(sim, Val(:area_fraction), colidx)
                area_mask  = Regridder.binary_mask.(area_fraction, threshold = eps())

                if !iszero(parent(area_mask))

                    thermo_state_sfc = surface_thermo_state(sim, thermo_params, thermo_state_int, colidx)

                    # set inputs based on whether the surface_scheme is MOST or bulk
                    inputs = surface_inputs(
                        surface_scheme,
                        thermo_state_sfc,
                        thermo_state_int,
                        uₕ_int,
                        z_int,
                        z_sfc,
                        get_scheme_specific_properties(surface_scheme, sim, colidx)...,
                        )

                    # update fluxes in the coupler
                    surface_params = get_surface_params(atmos_sim)
                    F_ρτxz, F_ρτyz, F_shf, F_lhf, F_evap = get_surface_fluxes_point!(inputs, surface_params)

                    ρ_sfc = get_air_density(atmos_sim, thermo_params, thermo_state_sfc)

                    fields = (; F_ρτxz = F_ρτxz, F_ρτyz = F_ρτyz, F_shf = F_shf, F_lhf = F_lhf, F_evap = F_evap, ρ_sfc = ρ_sfc)

                    # update the fluxes of this surface model
                    update_turbulent_fluxes_point!(sim, fields, colidx)

                    # add the flux contributing from this surface
                    area_fraction = get_area_fraction(sim)[colidx]
                    mask = Regridder.binary_mask.(area_fraction, threshold = eps()) # only include flux calculations of unmasked surfaces
                    @. csf.F_ρτxz[colidx] += F_ρτxz * area_fraction * mask
                    @. csf.F_ρτyz[colidx] += F_ρτyz * area_fraction * mask
                    @. csf.F_shf[colidx] += F_shf * area_fraction * mask
                    @. csf.F_lhf[colidx] += F_lhf * area_fraction * mask
                    @. csf.F_evap[colidx] += F_evap * area_fraction * mask
                    # @. csf.ρ_sfc[colidx] += ρ_sfc
                    # @. csf.q_sfc[colidx] += q_sfc

                end
            end
        end

    end

    # update atmos fluxes (TODO: include to the above loop, with atmos_flux_reset)
    for sim in model_sims
        if sim isa AtmosModelSimulation
            Fields.bycolumn(boundary_space) do colidx
                coupler_fields = (; F_ρτxz = csf.F_ρτxz[colidx], F_ρτyz = csf.F_ρτyz[colidx], F_shf = csf.F_shf[colidx], F_lhf = csf.F_lhf[colidx], F_evap = csf.F_evap[colidx])
                update_turbulent_fluxes_point!(sim, coupler_fields, colidx)
            end
        end
    end
    # TODO: add allowable bounds here, check explicitly that all fluxes are equal

    # check_field = zeros(boundary_space)
    # for sim in model_sims
    #     if sim isa SurfaceModelSimulation
    #         check_field .+= get_sensible_heat_flux(sim)
    #     end
    # end
    # @assert(extrema(check_field .- get_sensible_heat_flux(atmos_sim)) ≈ (0.0, 0.0))

end

extra_aux_update(sim::SurfaceModelSimulation, _...) = nothing


function surface_thermo_state(sim::SurfaceModelSimulation, thermo_params, thermo_state_int, colidx)
    T_sfc = get_field(sim, Val(:air_temperature), colidx) #
    ρ_sfc = extrapolate_ρ_to_sfc.(thermo_params, thermo_state_int, T_sfc) # ideally the # calculate elsewhere, here just getter...
    q_sfc = TD.q_vap_saturation_generic.(thermo_params, T_sfc, ρ_sfc, TD.Liquid()) # default = saturated
    @. TD.PhaseEquil_ρTq.(thermo_params, ρ_sfc, T_sfc, q_sfc)
end



# test
# calculate_and_send_turbulent_fluxes!(cs)



"""
    collect_atmos_fluxes!(sim::AtmosSimulation, csf, sims)

Calculated in the atmosphere and collected after the atmos coupling timestep.
"""
function collect_atmos_fluxes!(csf, atmos_sim::AtmosModelSimulation)
    parent(csf.F_R_sfc) .= parent(get_net_surface_radiation(atmos_sim))
    parent(csf.P_liq) .= parent(get_liquid_precipitation(atmos_sim))
    parent(csf.P_snow) .= FT(0.0) # parent(get_snow_precipitation(atmos_sim))
    parent(csf.P_net) .= parent(csf.P_liq .+ csf.P_snow)
end

function push_atmos_fluxes!(sims, csf)
    for sfc_sim in sims
        if !(sfc_sim isa AtmosModelSimulation)
            frac = get_area_fraction(sfc_sim)
            isnothing(frac) ? continue : nothing
            mask = Regridder.binary_mask.(frac, threshold = eps()) # only include flux calculations of unmasked surfaces

            update!(sfc_sim, Val(:net_radiation), csf.F_R_sfc .* frac .* mask)
            update!(sfc_sim, Val(:precipitation_liquid), csf.P_liq .* frac .* mask)
            update!(sfc_sim, Val(:precipitation_snow), csf.P_snow .* frac .* mask)

        end
    end
end



"""
    inform_boundary_fluxes!(csf)

Informs calculations that occur in the atmosphere before atmos coupling time step.
"""

function collect_surface_state!(csf, sims)
    FT = eltype(csf[1])
    (; land_sim, ocean_sim, ice_sim) = sims

    # combine models' surfaces onlo one coupler field
    combine_surfaces!(csf.T_S, (; land = get_area_fraction(land_sim), ocean = get_area_fraction(ocean_sim), ice = get_area_fraction(ice_sim)), (; land = get_temperature(land_sim), ocean = get_temperature(ocean_sim), ice = get_temperature(ice_sim)))
    combine_surfaces!(csf.albedo, (; land = get_area_fraction(land_sim), ocean = get_area_fraction(ocean_sim), ice = get_area_fraction(ice_sim)), (; land = get_albedo(land_sim), ocean = get_albedo(ocean_sim), ice = get_albedo(ice_sim)))

end

function push_surface_state!(atmos_sim, csf)

    # update Atmos RRTMGP's albedos and surface temperature
    update!(atmos_sim, Val(:T_sfc), csf.T_S)
    update!(atmos_sim, Val(:albedo), csf.albedo)

end


"""
    get_surface_fluxes_point!

Uses SurfaceFluxes.jl to calculate turbulent surface fluxes. It should be atmos model agnostic, and columnwise.
"""
function get_surface_fluxes_point!(inputs, surface_params)

    # calculate all fluxes (saturated surface conditions)
    outputs = @. SF.surface_conditions(surface_params, inputs)

    # drag
    F_ρτxz = outputs.ρτxz
    F_ρτyz = outputs.ρτyz

    # energy fluxes
    F_shf = outputs.shf
    F_lhf = outputs.lhf

    # moisture
    F_evap = @. SF.evaporation(
        surface_params,
        inputs,
        outputs.Ch,
    )

    return F_ρτxz, F_ρτyz, F_shf, F_lhf, F_evap
end

# defailt for rho_sfc
function extrapolate_ρ_to_sfc(thermo_params, ts_in, T_sfc)
    T_int = TD.air_temperature(thermo_params, ts_in)
    Rm_int = TD.gas_constant_air(thermo_params, ts_in)
    ρ_air = TD.air_density(thermo_params, ts_in)
    ρ_air * (T_sfc / T_int)^(TD.cv_m(thermo_params, ts_in) / Rm_int)
end


function surface_thermo_state(
    sim::SurfaceModelSimulation,
    thermo_params,
    T_sfc,
    q_sfc,
    ρ_sfc,
)


    # ρ_sfc = # replace with model spec - e.g. Bucket: compute_ρ_sfc
    #     get_air_density(atmos_sim, thermo_params, thermo_state_int) .*
    #     (
    #         T_sfc ./ get_air_temperature(atmos_sim, thermo_params, thermo_state_int)
    #     ).^(
    #         get_cv_m(atmos_sim, thermo_params, thermo_state_int) ./
    #         get_gas_constant_air(atmos_sim, thermo_params, thermo_state_int)
    #     )

    # for saturated surfaces (water, ice, saturated land)
    if issaturated(sim, q_sfc)
        q_sfc = TD.q_vap_saturation_generic.(thermo_params, T_sfc, ρ_sfc, TD.Liquid())
    end

    # for unsaturated surfaces, q_sfc must be prescribed (land)
    return TD.PhaseEquil_ρTq.(thermo_params, ρ_sfc, T_sfc, q_sfc)
end

function get_scheme_specific_properties(::BulkScheme, sim, colidx)
    Ch = get_heat_transfer_coefficient_point(sim, colidx)
    Cd = get_drag_transfer_coefficient_point(sim, colidx)
    beta = get_beta_point(sim, colidx)
    FT = eltype(Ch)
    return (; z0b = FT(0), z0m = FT(0), Ch = Ch, Cd = Cd, beta = beta, gustiness = FT(1))
end
function surface_inputs(
    ::BulkScheme,
    thermo_state_sfc,
    thermo_state_int,
    uₕ_int,
    z_int,
    z_sfc,
    z0b,
    z0m,
    Ch,
    Cd,
    beta,
    gustiness,
)
    FT = Spaces.undertype(axes(z_sfc))

    # wrap state values
    return @. SF.Coefficients(
        SF.InteriorValues(z_int, uₕ_int, thermo_state_int), # state_in                              # state_sfc
        SF.SurfaceValues(                                  # state_sfc
            z_sfc,
            StaticArrays.SVector(FT(0), FT(0)),
            thermo_state_sfc,
        ),
        Cd,                                     # Cd
        Ch,                                     # Ch
        z0m,                                             # z0m
        z0b,                                             # z0b
        gustiness,                                             # gustiness
        beta,                                   # beta
    )
end

function get_scheme_specific_properties(::MoninObukhovScheme, sim, colidx)
    z0m = get_z0m_point(sim, colidx)
    z0b = get_z0b_point(sim, colidx)
    beta = get_beta_point(sim, colidx)
    return (; z0b = z0b, z0m = z0m, Ch = FT(0), Cd = FT(0), beta= beta, gustiness = FT(1))
end

function surface_inputs(
    ::MoninObukhovScheme,
    thermo_state_sfc,
    thermo_state_int,
    uₕ_int,
    z_int,
    z_sfc,
    z0b,
    z0m,
    Ch,
    Cd,
    beta,
    gustiness,
)
    FT = Spaces.undertype(axes(z_sfc))

    # wrap state values

    return @. SF.ValuesOnly(
        SF.InteriorValues(z_int, uₕ_int, thermo_state_int), # state_in
        SF.SurfaceValues(                                  # state_sfc
            z_sfc,
            StaticArrays.SVector(FT(0), FT(0)),
            thermo_state_sfc,
        ),
        z0m,                                    # z0m
        z0b,                                    # z0b
        FT(-1),                                            # L_MO_init
        gustiness,                                             # gustiness
        beta                                   # beta
    )

end