#=

    In this module we write code to perform a multi-parameter linear least squares fit using a julia wrapper for the C GSL library. In particular, the specific functional form to which we fit is the Fourier-series expansion of geodesic orbital
    functionals in terms of their fundamental frequencies (see arXiv:1109.0572v2, arXiv:astro-ph/0308479v3). This fit can be done in either Mino time or coordinate, but, of course, the Fourier series coefficients one obtains would be different in each case.
    In principle, one could change the way one constructs the fitting frequencies from the fundamental frequencies in the Fourier series expansion---since the sum is infinite, there is not a unique way to sum over a `small' number of frequencies.
    We also emphasise the limitations of this fitting scheme---we have found that it works incredibly well in aproximating high order derivatives of orbital function, e.g., of the order 1 part in 10^{5} for the sixth derivative. However, this seems
    to be a consequence of overfitting, and not necessarily because the solver can correctly select out the dominant modes in the Fourier domain power spectrum. That is, we have performed checks where we fit to some orbital functional, say
    f(t; r, θ, ϕ) = r cos(θ) sin(ϕ), and found that while the fit is excellent and the derivatie approximations are also accurate (in particular the error jumps by about a factor of 10 fot each extra derivative until ~1 part in 10^{5} for the sixth),
    we have consistently found that if one plots the power spectrum of the fourier series coefficients (sqrt(A_{kmn}^{2} + B_{kmn}^{2})) versus the fourier transform of f, the spectra are not aligned. That is, the solver is not selecting out the
    dominant modes in the power spectrum of the function. As such, for use as a black box to estimate derivatives of some orbital fucntional, this method is useful up to order 6 or so, but one should be cautious about using it for other purposes.

=#

module FourierFitGSL
using GSL

"""
# Common Arguments in this module
- `nHarm::Int64`: Number of harmonic frequencies in the fit. This is the number of distinct coefficients of the radial frequency in the fit (see Notes).
- `Ω::Vector{<:Number}`: three-vector of fundamental frequencies in the fit. For fits in BL time, this should be [Ωr, Ωθ, Ωϕ], and in Mino time, this should be [ωr, ωθ, ωϕ].
- `nPoints::Int64`: Number of data points to be fit.
- `nFreqs::Int64`: Number of fitting frequencies---this is set when one chooses the number of harmonic frequencies.
- `fit_params::Vector{<:Number}`: Vector of fit parameters. The first element is the constant term, and the rest are the coefficients of the sin and cos terms for each fitting frequency.
- `nParams::Int64`: Number of fit parameters. This is 2 * nFreqs + 1, where the +1 is for the constant term, and the factor of 2 is for the sin and cos terms for each fitting frequency.
- `xdata::Vector{<:Number}`: Vector of x-values for the data to be fit (this should be a vector of coordinate time or Mino time).
- `ydata::Vector{<:Number}`: Vector of y-values for the data to be fit (this should be a vector of the orbital functional data).

# Notes
- The relevant equations in arXiv:1109.0572v2 are Eqs. 98-99, though we perform the fit here in terms of sines and cosines, so that there are two coefficients for each fitting frequency.
- The number of harmonics, nHarm, is the number of coefficients of the radial frequency in the fit. The fitting frequencies are then constructed by summing over integer multiples of the the fundamental frequencies, with multiples of the radial
frequency ranging from k = 0 to nHarm, multiples of the polar frequency ranging from m = -k to nHarm, and multiples of the azimuthal frequency ranging from l = -(k+m) to nHarm. This is the convention followed in (arXiv:1109.0572v2), but, of course, this
construction is not unique.
- We provide master functions that allow one to perform the fits without specifying the number of fundamental frequencies explicitly. For example, for an equatorial orbit, the polar frequency is infinite, and the functions we provide for computing the
fundamental frequencies will set their value to 1e12. The master functions select out the frequencies which are <1e9, and thus only those that are well defined. They then proceed to fit with only these fundamental frequencies.
"""

# compute number of fitting frequencies for fits with one, two, and three fundamental frequencies for a given harmonic (-1 since we don't count constant term)
compute_num_fitting_freqs_1(nHarm::Int64) = nHarm
compute_num_fitting_freqs_2(nHarm::Int64) = Int((nHarm * (5 + 3 * nHarm) / 2))
compute_num_fitting_freqs_3(nHarm::Int64) = Int( nHarm * (13 + 2 * nHarm * (9 + 4 * nHarm)) / 3)

function compute_num_fitting_freqs_master(nHarm::Int64, Ω::AbstractVector{Float64})
    num_freqs = sum(Ω .< 1e9)
    if num_freqs==3
        compute_num_fitting_freqs_3(nHarm)
    elseif num_freqs==2
        compute_num_fitting_freqs_2(nHarm)
    elseif num_freqs==1
        compute_num_fitting_freqs_1(nHarm)
    end
end


# construct fitting frequencies for one fundamental frequency
function compute_fitting_frequencies_1(nHarm::Int64, Ωr::Float64)
    Ω = Float64[]
    @inbounds for i_r in 1:nHarm
        append!(Ω, i_r * Ωr)
    end
    return Ω
end

# chimera construct fitting frequencies
function compute_fitting_frequencies_2(nHarm::Int64, Ωr::Float64, Ωθ::Float64)
    Ω = Float64[]
    @inbounds for i_r in 0:nHarm
        @inbounds for i_θ in -i_r:nHarm
            (i_r==0 && i_θ==0) ? nothing : append!(Ω, abs(i_r * Ωr + i_θ * Ωθ))
        end
    end
    return Ω
end


# chimera construct fitting frequencies
function compute_fitting_frequencies_3(nHarm::Int64, Ωr::Float64, Ωθ::Float64, Ωϕ::Float64)
    Ω = Float64[]
    @inbounds for i_r in 0:nHarm
        @inbounds for i_θ in -i_r:nHarm
            @inbounds for i_ϕ in -(i_r+i_θ):nHarm
                (i_r==0 && i_θ==0 && i_ϕ==0) ? nothing : append!(Ω, abs(i_r * Ωr + i_θ * Ωθ + i_ϕ * Ωϕ))
            end
        end
    end
    return Ω
end

function compute_fitting_frequencies_master(nHarm::Int64, Ω::AbstractVector{Float64})
    freqs = Ω[Ω .< 1e9];
    num_freqs = length(freqs);
    if num_freqs==1
        compute_fitting_frequencies_1(nHarm, freqs...)
    elseif num_freqs==2
        compute_fitting_frequencies_2(nHarm, freqs...)
    elseif num_freqs==3
        compute_fitting_frequencies_3(nHarm, freqs...)
    end
end

# functional form to which we fit data
function curve_fit_functional(f::AbstractVector{Float64}, tdata::AbstractVector{Float64}, Ω::AbstractVector{Float64}, params::AbstractVector{Float64}, n_freqs::Int64)
    @inbounds Threads.@threads for i in eachindex(tdata)
        f[i]=params[1]    # first parameter is the constant term
        @inbounds for j in eachindex(Ω)
            f[i] += params[j+1] * cos(Ω[j] * tdata[i]) + params[n_freqs + j+1] * sin(Ω[j] * tdata[i])
        end
    end
    return f
end

# compute Nth derivative
function curve_fit_functional_derivs(tdata::AbstractVector{Float64}, Ω::AbstractVector{Float64}, params::AbstractVector{Float64}, n_freqs::Int64, n_points::Int64, N::Int64)
    # if computing the functional form (i.e., zeroth derivative), then must include constant term
    f = N==0 ? params[1] * ones(n_points) : zeros(n_points)
    @inbounds for i in eachindex(tdata)
        for j in eachindex(Ω)  
            f[i] += (Ω[j]^N) * (params[j+1] * cos(Ω[j] * tdata[i] + N*π/2) + params[n_freqs + j+1] * sin(Ω[j] * tdata[i] + N*π/2))
        end
    end
    return f
end

# row constructor for predictor matrix in GSL fit
function GSL_fourier_model(t::AbstractVector{Float64}, Ω::AbstractVector{Float64}, n_freqs::Int64)
    f=ones(n_freqs+1)
    @inbounds for i in 1:n_freqs
        f[i+1] = cos(Ω[i] * t)
        f[i+1+n_freqs] = sin(Ω[i] * t)
    end
    return f
end

# allocate memory for fitting method input
function allocate_memory(n_p::Int64, n_coeffs::Int64)
    x = GSL.vector_alloc(n_p)
    y = GSL.vector_alloc(n_p)
    X = GSL.matrix_alloc(n_p, n_coeffs)
    c = GSL.vector_alloc(n_coeffs)
    cov = GSL.matrix_alloc(n_coeffs, n_coeffs)
    work = GSL.multifit_linear_alloc(n_p, n_coeffs)
    return x, y, X, c, cov, work
end

# free memory used for fitting
function free_memory!(x::Ptr{gsl_vector}, y::Ptr{gsl_vector}, X::Ptr{gsl_matrix}, c::Ptr{gsl_vector}, cov::Ptr{gsl_matrix}, work::Ptr{gsl_multifit_linear_workspace})
    GSL.vector_free(x)
    GSL.vector_free(y)
    GSL.matrix_free(X)
    GSL.vector_free(c)
    GSL.matrix_free(cov)
    GSL.multifit_linear_free(work)
end

# fill GSL vectors 'xdata' and 'ydata' for the fit
function fill_gsl_vectors!(xGSL::Ptr{gsl_vector}, yGSL::Ptr{gsl_vector}, x::AbstractVector{Float64}, y::AbstractVector{Float64}, n_p::Int64)
    @inbounds Threads.@threads for i=0:(n_p-1)
        GSL.vector_set(xGSL, i, x[i+1])
        GSL.vector_set(yGSL, i, y[i+1])
    end
end

#=

    The predictor matrix X has a number of rows equal to the number of y-values to which we are fitting. Each row consists of the functional form to which we are fitting evaluated decomposed into its constituent terms and
    evaluated at a given element of the x vector. The input function 'model' must output a vector whose elements are the componenets of the functional form. In other words, if the function form we are fitting to is f(x),
    then we must have f(x) = sum(model(x))

=#

# row constructor for predictor matrix in GSL fit
function GSL_fourier_model(t::Float64, Ω::AbstractVector{Float64}, n_freqs::Int64,  n_coeffs::Int64)
    f=ones(n_coeffs)    # a constant term, and then a cosine and sine term for each fitting frequency
    @inbounds for i in 1:n_freqs
        f[i+1] = cos(Ω[i] * t)
        f[i+1+n_freqs] = sin(Ω[i] * t)
    end
    return f
end

# fill predictor matrix X: N is number of harmonics, and Ω_fit is the fitting frequencies
function fill_predictor_matrix!(X::Ptr{gsl_matrix}, x::AbstractVector{Float64}, n_p::Int64, n_freqs::Int64,  n_coeffs::Int64, Ω_fit::AbstractVector{Float64})
    # construct the fit matrix X 
    @inbounds Threads.@threads for i=0:n_p-1
        Xij = FourierFitGSL.GSL_fourier_model(x[i+1], Ω_fit, n_freqs, n_coeffs)
        # fill in row i of X 
        for j=0:(2 * n_freqs)
            GSL.matrix_set(X, i, j, Xij[j+1])
        end
    end
end

# call multilinear fit
function curve_fit!(y::Ptr{gsl_vector}, X::Ptr{gsl_matrix}, c::Ptr{gsl_vector}, cov::Ptr{gsl_matrix}, work::Ptr{gsl_multifit_linear_workspace}, chisq::AbstractVector{Float64})
    GSL.multifit_linear(X, y, c, cov, chisq, work)
end

# master functions for carrying out fit with one, two or three fundamental frequencies
function GSL_fit_1!(xdata::AbstractVector{Float64}, ydata::AbstractVector{Float64}, n_p::Int64, nHarm::Int64, chisq::AbstractVector{Float64},  Ω1::Float64, fit_params::AbstractVector{Float64})
    # compute fitting frequncies and their Float64
    Ω_fit = FourierFitGSL.compute_fitting_frequencies_1(nHarm, Ω1)
    n_freqs = compute_num_fitting_freqs_1(nHarm)
    n_coeffs = 2 * n_freqs + 1    # +1 to allocate memory for the constant term, and factor of 2 since we have sin and cos for each frequency

    # allocate memory and fill GSL vectors and matrices
    x, y, X, c, cov, work = FourierFitGSL.allocate_memory(n_p, n_coeffs)
    FourierFitGSL.fill_gsl_vectors!(x, y, xdata, ydata, n_p)
    FourierFitGSL.fill_predictor_matrix!(X, xdata, n_p, n_freqs, n_coeffs, Ω_fit)

    # carry out fit and store best fit params
    # println("Carrying out fit")
    FourierFitGSL.curve_fit!(y, X, c, cov, work, chisq)
    @views fit_params[:] = GSL.wrap_gsl_vector(c)

    # free memory
    FourierFitGSL.free_memory!(x, y, X, c, cov, work)
    return Ω_fit
end

function GSL_fit_2!(xdata::AbstractVector{Float64}, ydata::AbstractVector{Float64}, n_p::Int64, nHarm::Int64, chisq::AbstractVector{Float64},  Ω1::Float64, Ω2::Float64, fit_params::AbstractVector{Float64})
    # compute fitting frequncies and their Float64
    Ω_fit = FourierFitGSL.compute_fitting_frequencies_2(nHarm, Ω1, Ω2)
    n_freqs = compute_num_fitting_freqs_2(nHarm)
    n_coeffs = 2 * n_freqs + 1    # +1 to allocate memory for the constant term, and factor of 2 since we have sin and cos for each frequency

    # allocate memory and fill GSL vectors and matrices
    x, y, X, c, cov, work = FourierFitGSL.allocate_memory(n_p, n_coeffs)
    FourierFitGSL.fill_gsl_vectors!(x, y, xdata, ydata, n_p)
    FourierFitGSL.fill_predictor_matrix!(X, xdata, n_p, n_freqs, n_coeffs, Ω_fit)

    # carry out fit and store best fit params
    # println("Carrying out fit")
    FourierFitGSL.curve_fit!(y, X, c, cov, work, chisq)
    @views fit_params[:] = GSL.wrap_gsl_vector(c)

    # free memory
    FourierFitGSL.free_memory!(x, y, X, c, cov, work)
    return Ω_fit
end

function GSL_fit_3!(xdata::AbstractVector{Float64}, ydata::AbstractVector{Float64}, n_p::Int64, nHarm::Int64, chisq::AbstractVector{Float64},  Ω1::Float64, Ω2::Float64, Ω3::Float64, fit_params::AbstractVector{Float64})
    # compute fitting frequncies and their Float64
    Ω_fit = FourierFitGSL.compute_fitting_frequencies_3(nHarm, Ω1, Ω2, Ω3)
    n_freqs = compute_num_fitting_freqs_3(nHarm)
    n_coeffs = 2 * n_freqs + 1    # +1 to allocate memory for the constant term, and factor of 2 since we have sin and cos for each frequency

    # allocate memory and fill GSL vectors and matrices
    x, y, X, c, cov, work = FourierFitGSL.allocate_memory(n_p, n_coeffs)
    FourierFitGSL.fill_gsl_vectors!(x, y, xdata, ydata, n_p)
    FourierFitGSL.fill_predictor_matrix!(X, xdata, n_p, n_freqs, n_coeffs, Ω_fit)

    # carry out fit and store best fit params
    # println("Carrying out fit")
    FourierFitGSL.curve_fit!(y, X, c, cov, work, chisq)
    @views fit_params[:] = GSL.wrap_gsl_vector(c)

    # free memory
    FourierFitGSL.free_memory!(x, y, X, c, cov, work)
    return Ω_fit
end

function GSL_fit_master!(xdata::AbstractVector{Float64}, ydata::AbstractVector{Float64}, n_p::Int64, nHarm::Int64, chisq::AbstractVector{Float64},  Ω::AbstractVector{Float64}, fit_params::AbstractVector{Float64})
    freqs = Ω[Ω .< 1e9];
    num_freqs = length(freqs);
    if num_freqs==1
        GSL_fit_1!(xdata, ydata, n_p, nHarm, chisq, freqs..., fit_params)
    elseif num_freqs==2
        GSL_fit_2!(xdata, ydata, n_p, nHarm, chisq, freqs..., fit_params)
    elseif num_freqs==3
        GSL_fit_3!(xdata, ydata, n_p, nHarm, chisq, freqs..., fit_params)
    end
end

end