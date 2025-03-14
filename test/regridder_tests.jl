#=
    Unit tests for ClimaCoupler Regridder module
=#
import Test: @testset, @test, @test_logs
import Dates
import NCDatasets
import ClimaComms
@static pkgversion(ClimaComms) >= v"0.6" && ClimaComms.@import_required_backends
import ClimaCore as CC
import ClimaCoupler
import ClimaCoupler: Interfacer, Regridder, TimeManager

include("TestHelper.jl")
import .TestHelper

const comms_ctx = ClimaComms.SingletonCommsContext()
const pid, nprocs = ClimaComms.init(comms_ctx)

struct TestSurfaceSimulationA <: Interfacer.SurfaceModelSimulation end
struct TestSurfaceSimulationB <: Interfacer.SurfaceModelSimulation end
struct TestSurfaceSimulationC <: Interfacer.SurfaceModelSimulation end
struct TestSurfaceSimulationD <: Interfacer.SurfaceModelSimulation end

# Initialize weights (fractions) and initial values (fields)
Interfacer.get_field(::TestSurfaceSimulationA, ::Val{:random}) = 1.0
Interfacer.get_field(::TestSurfaceSimulationB, ::Val{:random}) = 1.0
Interfacer.get_field(::TestSurfaceSimulationC, ::Val{:random}) = 1.0
Interfacer.get_field(::TestSurfaceSimulationD, ::Val{:random}) = 1.0

Interfacer.get_field(::TestSurfaceSimulationA, ::Val{:area_fraction}) = 0.0
Interfacer.get_field(::TestSurfaceSimulationB, ::Val{:area_fraction}) = 0.5
Interfacer.get_field(::TestSurfaceSimulationC, ::Val{:area_fraction}) = 2.0
Interfacer.get_field(::TestSurfaceSimulationD, ::Val{:area_fraction}) = -10.0

struct DummyStub{C} <: Interfacer.SurfaceModelSimulation
    cache::C
end
Interfacer.get_field(sim::DummyStub, ::Val{:area_fraction}) = sim.cache.area_fraction
function Interfacer.update_field!(sim::DummyStub, ::Val{:area_fraction}, field::CC.Fields.Field)
    sim.cache.area_fraction .= field
end

for FT in (Float32, Float64)
    @testset "test dummmy_remap!" begin
        test_space = TestHelper.create_space(FT)
        test_field_ones = CC.Fields.ones(test_space)
        target_field = CC.Fields.zeros(test_space)

        Regridder.dummmy_remap!(target_field, test_field_ones)
        @test parent(target_field) == parent(test_field_ones)
    end

    @testset "test update_surface_fractions!" begin
        test_space = TestHelper.create_space(FT)
        # Construct land fraction of 0s in top half, 1s in bottom half
        land_fraction = CC.Fields.ones(test_space)
        dims = size(parent(land_fraction))
        m = dims[1]
        n = dims[2]
        parent(land_fraction)[1:(m ÷ 2), :, :, :] .= FT(0)

        # Construct ice fraction of 0s on left, 0.5s on right
        ice_d = CC.Fields.zeros(test_space)
        parent(ice_d)[:, (n ÷ 2 + 1):n, :, :] .= FT(0.5)

        # Construct ice fraction of 0s on left, 0.5s on right
        ocean_d = CC.Fields.zeros(test_space)

        # Fill in only the necessary parts of the simulation
        cs = Interfacer.CoupledSimulation{FT}(
            nothing, # comms_ctx
            nothing, # dates
            nothing, # boundary_space
            nothing, # fields
            nothing, # parsed_args
            nothing, # conservation_checks
            (Int(0), Int(1000)), # tspan
            Int(200), # t
            Int(200), # Δt_cpl
            (;
                ice_sim = DummyStub((; area_fraction = ice_d)),
                ocean_sim = Interfacer.SurfaceStub((; area_fraction = ocean_d)),
                land_sim = DummyStub((; area_fraction = land_fraction)),
            ), # model_sims
            (;), # mode
            (;), # callbacks
            (;), # dirs
            nothing, # turbulent_fluxes
            nothing, # thermo_params
            nothing, # amip_diags_handler
        )

        Regridder.update_surface_fractions!(cs)

        # Test that sum of fractions is 1 everywhere
        ice_fraction = Interfacer.get_field(cs.model_sims.ice_sim, Val(:area_fraction))
        ocean_fraction = Interfacer.get_field(cs.model_sims.ocean_sim, Val(:area_fraction))
        @test all(parent(ice_fraction .+ ocean_fraction .+ land_fraction) .== FT(1))
    end

    @testset "test combine_surfaces_from_sol!" begin
        test_space = TestHelper.create_space(FT)
        combined_field = CC.Fields.ones(test_space)

        # Initialize weights (fractions) and initial values (fields)
        fractions = (a = 0.0, b = 0.5, c = 2.0, d = -10.0)
        fields = (a = 1.0, b = 1.0, c = 1.0, d = 1.0)

        Regridder.combine_surfaces_from_sol!(combined_field::CC.Fields.Field, fractions::NamedTuple, fields::NamedTuple)
        @test all(parent(combined_field) .== FT(sum(fractions) * sum(fields) / length(fields)))
    end

    @testset "test combine_surfaces" begin
        test_space = TestHelper.create_space(FT)
        combined_field = CC.Fields.ones(test_space)

        var_name = Val(:random)
        sims = (;
            a = TestSurfaceSimulationA(),
            b = TestSurfaceSimulationB(),
            c = TestSurfaceSimulationC(),
            d = TestSurfaceSimulationD(),
        )

        fractions = (
            a = Interfacer.get_field(sims.a, Val(:area_fraction)),
            b = Interfacer.get_field(sims.b, Val(:area_fraction)),
            c = Interfacer.get_field(sims.c, Val(:area_fraction)),
            d = Interfacer.get_field(sims.d, Val(:area_fraction)),
        )
        fields = (
            a = Interfacer.get_field(sims.a, var_name),
            b = Interfacer.get_field(sims.b, var_name),
            c = Interfacer.get_field(sims.c, var_name),
            d = Interfacer.get_field(sims.d, var_name),
        )

        Regridder.combine_surfaces!(combined_field, sims, var_name)
        @test all(parent(combined_field) .== FT(sum(fractions) * sum(fields) / length(fields)))
    end

    @testset "test get_time" begin
        # Set up regrid directory for this test only
        mktempdir(pwd()) do regrid_dir
            # Test dataset containing times
            data_path = joinpath(regrid_dir, "data_times.nc")
            varname = "test_data"
            TestHelper.gen_ncdata_time(FT, data_path, varname, FT(1))
            NCDatasets.NCDataset(data_path, "r") do ds
                @test Regridder.get_time(ds) == Dates.DateTime.(Array(ds["time"]))
            end

            # Test warning when no dates are available in input data file
            data_path = joinpath(regrid_dir, "data_no_times.nc")
            varname = "test_data"
            TestHelper.gen_ncdata(FT, data_path, varname, FT(1))
            NCDatasets.NCDataset(data_path, "r") do ds
                @test_logs (:warn, "No dates available in input data file") Regridder.get_time(ds)
            end
        end
    end

    # Add tests which use TempestRemap here -
    # TempestRemap is not built on Windows because of NetCDF support limitations
    if !Sys.iswindows()
        @testset "test write_to_hdf5 and read_from_hdf5" begin
            # Set up regrid directory for this test only
            mktempdir(pwd()) do regrid_dir
                hd_outfile_root = "hdf5_out_test"
                tx = Dates.DateTime(1979, 01, 01, 01, 00, 00)
                test_space = TestHelper.create_space(FT)
                input_field = CC.Fields.ones(test_space)
                varname = "testdata"

                Regridder.write_to_hdf5(regrid_dir, hd_outfile_root, tx, input_field, varname, comms_ctx)

                output_field = Regridder.read_from_hdf5(regrid_dir, hd_outfile_root, tx, varname, comms_ctx)
                @test parent(input_field) == parent(output_field)
            end
        end

        @testset "test remap_field_cgll_to_rll for FT=$FT" begin
            # Set up regrid directory for this test only
            mktempdir(pwd()) do regrid_dir
                name = "testdata"
                datafile_rll = regrid_dir * "/" * name * "_rll.nc"

                test_space = TestHelper.create_space(FT)
                field = CC.Fields.ones(test_space)

                Regridder.remap_field_cgll_to_rll(name, field, regrid_dir, datafile_rll)

                # Test no new extrema are introduced in monotone remapping
                nt = NCDatasets.NCDataset(datafile_rll) do ds
                    max_remapped = maximum(ds[name])
                    min_remapped = minimum(ds[name])
                    (; max_remapped, min_remapped)
                end
                (; max_remapped, min_remapped) = nt

                @test max_remapped <= maximum(field)
                @test min_remapped >= minimum(field)
            end
        end

        @testset "test land_fraction for FT=$FT" begin
            # Test setup
            R = FT(6371e3)
            test_space = TestHelper.create_space(FT, R = R)

            # Set up regrid directory for this test only
            mktempdir(pwd()) do regrid_dir
                # Initialize dataset of all ones
                data_path = joinpath(regrid_dir, "ls_mask_data.nc")
                varname = "test_data"
                TestHelper.gen_ncdata_time(FT, data_path, varname, FT(1))

                # Test monotone masking
                land_fraction_mono =
                    Regridder.land_fraction(FT, regrid_dir, comms_ctx, data_path, varname, test_space, mono = true)

                # Test no new extrema are introduced in monotone remapping
                nt = NCDatasets.NCDataset(data_path) do ds
                    max_val = maximum(ds[varname])
                    min_val = minimum(ds[varname])
                    (; max_val, min_val)
                end
                (; max_val, min_val) = nt

                @test maximum(land_fraction_mono) <= max_val
                @test minimum(land_fraction_mono) >= min_val

                # Test that monotone remapping a dataset of all ones conserves surface area
                @test sum(land_fraction_mono) - 4 * π * (R^2) < 10e-14
            end

            # Set up regrid directory for this test only
            mktempdir(pwd()) do regrid_dir
                # Initialize dataset of all 0.5s
                data_path = joinpath(regrid_dir, "ls_mask_data.nc")
                varname = "test_data_halves"
                TestHelper.gen_ncdata_time(FT, data_path, varname, FT(0.5))

                # Test non-monotone masking
                land_fraction_halves =
                    Regridder.land_fraction(FT, regrid_dir, comms_ctx, data_path, varname, test_space, mono = false)

                # fractioning of values below threshold should result in 0
                @test all(parent(land_fraction_halves) .== FT(0))
            end
        end

        @testset "test hdwrite_regridfile_rll_to_cgll 3d space for FT=$FT" begin
            # Set up regrid directory for this test only
            mktempdir(pwd()) do regrid_dir
                # Test setup
                R = FT(6371e3)
                space = TestHelper.create_space(FT, nz = 2, ne = 16, R = R)

                # lat-lon dataset
                data = ones(720, 360, 2, 3) # (lon, lat, z, time)
                time = [19000101.0, 19000201.0, 19000301.0]
                lats = collect(range(-90, 90, length = 360))
                lons = collect(range(-180, 180, length = 720))
                z = [1000.0, 2000.0]
                data = reshape(sin.(lats * π / 90)[:], 1, :, 1, 1) .* data
                varname = "sinlat"

                # save the lat-lon data to a netcdf file in the required format for TempestRemap
                datafile_rll = joinpath(regrid_dir, "lat_lon_data.nc")
                NCDatasets.NCDataset(datafile_rll, "c") do ds
                    NCDatasets.defDim(ds, "lat", size(lats)...)
                    NCDatasets.defDim(ds, "lon", size(lons)...)
                    NCDatasets.defDim(ds, "z", size(z)...)
                    NCDatasets.defDim(ds, "date", size(time)...)

                    NCDatasets.defVar(ds, "lon", lons, ("lon",))
                    NCDatasets.defVar(ds, "lat", lats, ("lat",))
                    NCDatasets.defVar(ds, "z", z, ("z",))
                    NCDatasets.defVar(ds, "date", time, ("date",))

                    NCDatasets.defVar(ds, varname, data, ("lon", "lat", "z", "date"))
                end

                hd_outfile_root = "data_cgll_test"
                Regridder.hdwrite_regridfile_rll_to_cgll(
                    FT,
                    regrid_dir,
                    datafile_rll,
                    varname,
                    space,
                    mono = true,
                    hd_outfile_root = hd_outfile_root,
                )

                # read in data on CGLL grid from the last saved date
                date1 = TimeManager.strdate_to_datetime.(string(Int(time[end])))
                cgll_path = joinpath(regrid_dir, "$(hd_outfile_root)_$date1.hdf5")
                hdfreader = CC.InputOutput.HDF5Reader(cgll_path, comms_ctx)
                T_cgll = CC.InputOutput.read_field(hdfreader, varname)
                Base.close(hdfreader)

                # regrid back to lat-lon
                datafile_latlon = joinpath(regrid_dir, "remapped_latlon.nc")
                nlat = 360
                nlon = 720
                Regridder.remap_field_cgll_to_rll(:var, T_cgll, regrid_dir, datafile_latlon, nlat = nlat, nlon = nlon)
                T_rll, _ = Regridder.read_remapped_field(:var, datafile_latlon)

                # check consistency across z-levels
                @test T_rll[:, :, 1] == T_rll[:, :, 2]

                # check consistency of CGLL remapped data with original data
                @test all(isapprox.(extrema(data), extrema(parent(T_cgll)), atol = 1e-2))

                # check consistency of lat-lon remapped data with original data
                @test all(isapprox.(extrema(data), extrema(T_rll), atol = 1e-3))

                # visual inspection
                # Plots.plot(T_cgll) # using ClimaCorePlots
                # Plots.contourf(Array(T_rll)[:,1])
            end
        end
    end
end

# test dataset truncation
@testset "test dataset truncation" begin
    # Set up regrid directory for this test only
    mktempdir(pwd()) do regrid_dir
        # Create a dummy dataset for testing
        test_data_all = joinpath(regrid_dir, "test_truncation.nc")
        ds = NCDatasets.NCDataset(test_data_all, "c")
        NCDatasets.defDim(ds, "time", 100)
        NCDatasets.defDim(ds, "lat", 32)
        NCDatasets.defDim(ds, "lon", 64)
        dates = Dates.DateTime.(1923:2022)
        first_date = dates[1]
        last_date = last(dates)
        NCDatasets.defVar(ds, "time", dates, ("time",);)
        NCDatasets.defVar(ds, "lat", 1:32, ("lat",);)
        NCDatasets.defVar(ds, "lon", 1:64, ("lon",);)
        dummy_data = reshape(1:(32 * 64 * 100), 64, 32, 100)
        NCDatasets.defVar(ds, "dummy_var", dummy_data, ("lon", "lat", "time"))
        ds.attrib["title"] = "dummy dataset"
        close(ds)
        # set up comms_ctx
        device = ClimaComms.device()
        comms_ctx_device = ClimaComms.context(device)
        ClimaComms.init(comms_ctx_device)

        # values for the truncations
        t_start = 0.0
        t_end = 1.728e6
        date0test = ["18690101", "19230101", "19790228", "20220301", "20230101"]
        for date in date0test
            date0 = Dates.DateTime(date, Dates.dateformat"yyyymmdd")
            test_data = Regridder.truncate_dataset(
                test_data_all,
                "test_truncation",
                "dummy_var",
                regrid_dir,
                date0,
                t_start,
                t_end,
                comms_ctx_device,
            )
            ds_truncated = NCDatasets.NCDataset(test_data, "r")
            ds = NCDatasets.NCDataset(test_data_all, "r")
            new_dates = ds_truncated["time"][:]

            date_start = date0 + Dates.Second(t_start)
            date_end = date0 + Dates.Second(t_start + t_end)

            # start date is before the first date of datafile
            if date_start < first_date
                @test new_dates[1] == first_date
                # start date is after the last date in datafile
            elseif date_start > last_date
                @test new_dates[1] == last_date
                # start date is within the bounds of the datafile
            else
                @test new_dates[1] <= date_start
                @test new_dates[2] >= date_start
            end

            # end date is before the first date of datafile
            if date_end < first_date
                @test last(new_dates) == first_date
                # end date is after the last date of datafile
            elseif date_end > last_date
                @test last(new_dates) == last_date
                # end date is within the bounds of datafile
            else
                @test last(new_dates) >= date_end
                @test new_dates[length(new_dates) - 1] <= date_end
            end

            # check that truncation is indexing correctly
            all_data = ds["dummy_var"][:, :, :]
            new_data = ds_truncated["dummy_var"][:, :, :]
            (start_id, end_id) = Regridder.find_idx_bounding_dates(dates, date_start, date_end)
            @test new_data[:, :, 1] ≈ all_data[:, :, start_id]
            @test new_data[:, :, length(new_dates)] ≈ all_data[:, :, end_id]

            close(ds_truncated)
        end

        close(ds)
    end
end
