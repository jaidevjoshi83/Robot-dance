using JuMP
using Ipopt
using Printf
using Plots
using LinearAlgebra
using SparseArrays
import Statistics.mean

struct SEIR_Parameters
    ndays::Int64
    ncities::Int64
    s1::Vector{Float64}
    e1::Vector{Float64}
    i1::Vector{Float64}
    r1::Vector{Float64}
    V::SparseMatrixCSC{Float64,Int64}
    sumV::Vector{Float64}
    natural_rt::Float64
    tinc::Float64
    tinf::Float64
    function SEIR_Parameters(ndays, s1, e1, i1, r1)
        ls1 = length(s1)
        @assert length(e1) == ls1
        @assert length(i1) == ls1
        @assert length(r1) == ls1
        V = sparse(I, ls1, ls1)
        sumV = ones(ls1)
        new(ndays, ls1, s1, e1, i1, r1, V, sumV, 2.5, 5.2, 2.9)
    end
    function SEIR_Parameters(ndays, s1, e1, i1, r1, V)
        ls1 = length(s1)
        @assert length(e1) == ls1
        @assert length(i1) == ls1
        @assert length(r1) == ls1
        @assert size(V) == (ls1, ls1)
        @assert all(V .>= 0.0)
        sumV = vec(sum(V, dims=1))
        new(ndays, ls1, s1, e1, i1, r1, V, sumV, 2.5, 5.2, 2.9)
    end
end


function seir_grad(m, s, e, i, r, effect_rt, prm)
    ds = @NLexpression(m, [c=1:prm.ncities], -(effect_rt[c]/prm.tinf)*s[c]*i[c])
    de = @NLexpression(m, [c=1:prm.ncities], (effect_rt[c]/prm.tinf)*s[c]*i[c] - (1.0/prm.tinc)*e[c])
    di = @NLexpression(m, [c=1:prm.ncities], (1.0/prm.tinc)*e[c] - (1.0/prm.tinf)*i[c])
    dr = @NLexpression(m, [c=1:prm.ncities], (1.0/prm.tinf)*i[c])
    return ds, de, di, dr
end


function seir_model_with_free_initial_values(prm)
    m = Model(optimizer_with_attributes(Ipopt.Optimizer, "print_level" => 5))
    # For simplicity I am assuming that one step per day is OK.
    dt = 1.0

    # Note that I do not fix the initial state. It should be defined elsewhere.
    # State variables
    @variable(m, 0.0 <= s[1:prm.ncities, 1:prm.ndays] <= 1.0)
    @variable(m, 0.0 <= e[1:prm.ncities, 1:prm.ndays] <= 1.0)
    @variable(m, 0.0 <= i[1:prm.ncities, 1:prm.ndays] <= 1.0)
    @variable(m, 0.0 <= r[1:prm.ncities, 1:prm.ndays] <= 1.0)

    # Control variable
    @variable(m, 0.0 <= rt[1:prm.ncities, 1:prm.ndays] <= prm.natural_rt)

    effect_rt = @NLexpression(m, [c=1:prm.ncities, t=1:prm.ndays],
        1.0/prm.sumV[c] * sum(prm.V[i, c]*rt[i, t] for i = findnz(prm.V[:, c])[1])
    )

    # Implement Haun's method
    for t = 2:prm.ndays
        ds, de, di, dr = seir_grad(m, s[:, t - 1], e[:, t - 1], i[:, t - 1], r[:, t - 1], effect_rt[:, t - 1], prm)

        sp = @NLexpression(m, [c=1:prm.ncities], s[c, t - 1] + ds[c]*dt)
        ep = @NLexpression(m, [c=1:prm.ncities], e[c, t - 1] + de[c]*dt)
        ip = @NLexpression(m, [c=1:prm.ncities], i[c, t - 1] + di[c]*dt)
        rp = @NLexpression(m, [c=1:prm.ncities], r[c, t - 1] + dr[c]*dt)

        dsp, dep, dip, drp = seir_grad(m, sp, ep, ip, rp, effect_rt[:, t], prm)

        @NLconstraint(m, [c=1:prm.ncities], s[c, t] == s[c, t - 1] + 0.5*(ds[c] + dsp[c])*dt)
        @NLconstraint(m, [c=1:prm.ncities], e[c, t] == e[c, t - 1] + 0.5*(de[c] + dep[c])*dt)
        @NLconstraint(m, [c=1:prm.ncities], i[c, t] == i[c, t - 1] + 0.5*(di[c] + dip[c])*dt)
        @NLconstraint(m, [c=1:prm.ncities], r[c, t] == r[c, t - 1] + 0.5*(dr[c] + drp[c])*dt)
    end
    return m
end


function seir_model(prm)
    m = seir_model_with_free_initial_values(prm)

    # Initial state
    s1, e1, i1, r1 = m[:s][:, 1], m[:e][:, 1], m[:i][:, 1], m[:r][:, 1]
    for c in 1:prm.ncities
        fix(s1[c], prm.s1[c]; force=true)
        fix(e1[c], prm.e1[c]; force=true)
        fix(i1[c], prm.i1[c]; force=true)
        fix(r1[c], prm.r1[c]; force=true)
    end
    return m
end


# TODO: add cities
function control_rt_model(prm, max_i)
    prm.ndays = prm.ndays - 1
    m = seir_model(prm)
    rt, i = m[:rt], m[:i]

    # Rts can not change too fast.
    for t = 2:prm.ndays
        @constraint(m, 0.95*rt[t - 1] <= rt[t])
        @constraint(m, rt[t] <= 1.05*rt[t - 1])
    end

    # Limit infection
    for t = 1:prm.ndays
        @constraint(m, i[t] <= max_i)
    end

    # Maximize rt
    @objective(m, Max, sum(rt))

    return m
end


function fixed_rt_model(prm)
    m = seir_model(prm)
    rt = m[:rt]

    # Fix all rts
    for c = 1:prm.ncities
        for t = 1:prm.ndays
            fix(rt[c, t], prm.natural_rt; force=true)
        end
    end
    return m
end

function alternate_rt_model(prm)
    m = seir_model(prm)
    rt = m[:rt]
    i = m[:i]

    # Fix all rts of the first half cities in the firt half period
    for c = 1:div(prm.ncities, 2)
        for t = 1:div(prm.ndays, 2)
            fix(rt[c, t], prm.natural_rt; force=true)
        end
    end

    # Fix all rts of the second half cities in the second half period
    for c = div(prm.ncities, 2) + 1:prm.ncities
        for t = div(prm.ndays, 2) + 1:prm.ndays
            fix(rt[c, t], prm.natural_rt; force=true)
        end
    end

    # Calculate maximum i
    @constraint(m, lim[t=50:100], i[25,t] <= 0.06)
    @objective(m, Max, sum(i))
    return m
end

# TODO: add cities
"""
    fit_initcond_model(prm, initial_data)

Fit the initial parameters
"""
function fit_initcond_model(prm, initial_data)
    m = seir_model_with_free_initial_values(prm)
    prm.ndays = prm.ndays - 1

    # Initial state
    s0, e0, i, r0, rt = m[:s][0], m[:e][0], m[:i], m[:r][0], m[:rt]
    fix(r0, prm.r0; force=true)
    set_start_value(s0, prm.s0)
    set_start_value(e0, prm.e0)
    set_start_value(i[0], prm.i0)
    for t = 0:prm.ndays
        fix(rt[t], prm.natural_rt; force=true)
    end

    @constraint(m, s0 + e0 + i[0] + r0 == 1.0)
    # Compute a scaling factor so as a least square objetive makes more sense
    factor = 1.0/mean(initial_data)
    @objective(m, Min, sum((factor*(i[t] - initial_data[t + 1]))^2 for t = 0:prm.ndays))

    return m
end

# TODO: add cities
function test_control_rt(prm)
    #prm = SEIR_Parameters(365, 0.9999999183808258, 1.632383484751865e-06, 8.161917423759325e-07, 0.0)

    # First the uncontroled infection
    m = fixed_rt_model(prm)
    optimize!(m)
    iv = value.(m[:i]).data
    plot(iv, label="Uncontroled", lw=2)
    max_inf = maximum(iv)

     # Now controled infections
     targets = [0.01, 0.03, 0.05]
     for max_infection in targets
         m = control_rt_model(prm, max_infection)
         optimize!(m)
         plot!(value.(m[:i]).data, label="$max_infection", lw=2)
    end

    title!("Controlled Rt")
    xlabel!("days")
    ylabel!("rt")
    ylims!(0.0, max_inf + 0.005)
    yticks!(vcat([0.0], targets, [max_inf]), yformatter = yi -> @sprintf("%.2f", yi))
    xticks!([0, 100, 200, 300, 365])
end


# TODO: add cities
function fit_initial(data)
    prm = SEIR_Parameters(length(data), 0.0, 0.0, 0.0, 0.0)
    m = fit_initcond_model(prm, data)
    optimize!(m)
    return value(m[:s][0]), value(m[:e][0]), value(m[:i][0]), value(m[:r][0])
end
;

function test_mult_city(n)
    s1 = 0.999999918380825*ones(n)
    e1 = 1.632383484751865e-06*ones(n)
    i1 = 8.161917423759325e-07*ones(n)
    r1 = zeros(n)
    V = Matrix{Float64}(I, n, n)
    ind = x -> x <= n ? x : mod(x, n)
    for i = 1:n
        for j = div(n, 2):div(n, 2) + 5
            V[ind(i + j), i] = 0.1
        end
    end
    iparam = SEIR_Parameters(180, s1, e1, i1, r1, sparse(V))
    m = alternate_rt_model(iparam)
    return m, iparam
end
