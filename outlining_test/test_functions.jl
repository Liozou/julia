
"""
Identity function that removes type annotations. Force boxing of values.
"""
struct fuzz
    x::Any
    function fuzz(y)
        obj = new(y)
        return obj.x
    end
end



function nest(n::Int)
    x = n
    i = 1
    acc = 0
    y = 0
    while i < n
        while x > 0
            y = fuzz(x)
            acc += y
            x -= i
        end
        if y == 0
            x = i
            i = n
        else
            i += y
        end
    end
    return acc
end


function foo(x::Int)
    acc = 0
    if x<=-1
        return 0
    end
    while x>0
        y = fuzz(x)
        acc += y
        x -= 1
    end
    return acc
end


function bar(x)
    z = zero(x)
    try
        if x<0
            throw(x)
        end
        y = 2x
        z = y - x
    catch e
        z = x - e
    end
    return z
end


function two_args(x,y)
    return x+y
end


function before(n)
    if n<0
        n = -n
    end
    count = fuzz(0)
    for i in 1:n
        count += 1
    end
    return count
end


function recurse(n)
    if n == 0
        return 0
    end
    return 1 + recurse(n-1)
end


function measles(x)
    n = x
    if n > 0
        y = n
    else
        z = n
    end
    while abs(n) > 1
        n/=2
    end
    if n > 0
        return y
    else
        return z
    end
end
