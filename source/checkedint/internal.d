/**
Copyright: Copyright Thomas Stuart Bockman 2015
License: <a href="http://www.boost.org/LICENSE_1_0.txt">Boost License 1.0</a>.
Authors: Thomas Stuart Bockman
*/

module checkedint.internal;
import checkedint.flags;

import future.bitop, core.checkedint, std.algorithm, std.conv, std.math, future.traits;

@safe:

private:

template trueMax(N)
    if(isScalarType!N)
{
    static if(isSomeChar!N)
        enum trueMax = ~cast(N)0;
    else
        enum trueMax = N.max;
}

package:

template NumFromScal(N)
    if(isScalarType!N)
{
    static if(isNumeric!N)
        alias NumFromScal = N;
    else
    static if(isSomeChar!N)
        alias NumFromScal = IntFromChar!N;
    else //if(isBoolean!N)
        alias NumFromScal = ubyte;
}

/+pragma(inline, true) {+/
    // nothrow alternative to std.conv.to() using IntFlag
    T toImpl(T, bool throws, S)(const S value)
        if(isScalarType!T && isScalarType!S)
    {
        static if(throws)
            return to!T(value);
        else {
            static if(! isFloatingPoint!T) {
                static if(isFloatingPoint!S) {
                    if(value >= T.min) {
                        if(value > trueMax!T)
                            IntFlag.posOver.raise!throws();
                    } else
                        (value.isNaN? IntFlag.undef : IntFlag.negOver).raise!throws();
                } else {
                    static if(cast(long)S.min < cast(long)T.min) {
                        if(value < cast(S)T.min)
                            IntFlag.negOver.raise!throws();
                    }
                    static if(cast(ulong)trueMax!S > cast(ulong)trueMax!T) {
                        if(value > cast(S)trueMax!T)
                            IntFlag.posOver.raise!throws();
                    }
                }
            }
            return cast(T)value;
        }
    }

    int bsrImpl(bool throws, N)(const N num)
        if(isFixedPoint!N)
    {
        if(num == 0)
            IntFlag.undef.raise!throws();

        static assert(N.sizeof <= ulong.sizeof);
        alias WN = Select!(N.sizeof > size_t.sizeof, ulong, size_t);

        return bsr(cast(WN)num);
    }
    int bsfImpl(bool throws, N)(const N num)
        if(isFixedPoint!N)
    {
        if(num == 0)
            IntFlag.undef.raise!throws();

        static assert(N.sizeof <= ulong.sizeof);
        alias WN = Select!(N.sizeof > size_t.sizeof, ulong, size_t);

        return bsf(cast(WN)num);
    }

    auto byPow2Impl(string op, N, M)(const N left, const M exp) pure nothrow @nogc
        if(op.among!("*", "/", "%") && ((isFloatingPoint!N && isNumeric!M) || (isNumeric!N && isFloatingPoint!M)))
    {
        enum wantPrec = max(precision!N, precision!M);
        alias R =
            Select!(wantPrec <= precision!float, float,
            Select!(wantPrec <= precision!double, double, real));

        static if(isFloatingPoint!M) {
            R ret = void;

            static if(op.among!("*", "/")) {
                if(left == 0 && exp.isFinite)
                    ret = 0;
                else {
                    R wexp = cast(R)exp;
                    static if(op == "/")
                        wexp = -wexp;

                    ret = cast(R)left * exp2(wexp);
                }
            } else {
                const p2 = exp2(cast(R)exp);
                ret =
                    p2.isFinite? cast(R)left % p2 :
                    (p2 > 0)? cast(R)left :
                    (p2 < 0)? cast(R)0 :
                    R.nan;
            }

            return ret;
        } else {
            static if(op.among!("*", "/")) {
                int wexp =
                    (exp > int.max)? int.max :
                    (cast(long)exp < -int.max)? -int.max : cast(int)exp;
                static if(op == "/")
                    wexp = -wexp;

                return ldexp(cast(R)left, wexp);
            } else {
                int expL;
                real mantL = frexp(left, expL);

                static if(!isSigned!M)
                    const retL = expL <= exp;
                else
                    const retL = (expL < 0) || (expL <= exp);

                R ret = void;
                if(retL)
                    ret = left;
                else {
                    const expDiff = expL - exp;
                    ret = (expDiff > N.mant_dig)?
                        cast(R)0 :
                        left - ldexp(floor(ldexp(mantissa, expDiff)), expL - expDiff);
                }

                return ret;
            }
        }
    }
    auto byPow2Impl(string op, bool throws, N, M)(const N left, const M exp)
        if(op.among!("*", "/", "%") && isIntegral!N && isIntegral!M)
    {
        alias R = Select!(op.among!("*", "/") != 0, Promoted!N, N);
        enum Unsigned!M maxSh = 8 * N.sizeof - 1;

        R ret = void;
        static if(op.among!("*", "/")) {
            const rc = cast(R)left;
            const negE = exp < 0;
            const absE = cast(Unsigned!M)(negE?
                -exp :
                 exp);
            const bigSh = (absE > maxSh);

            R back = void;
            if((op == "*")? negE : !negE) {
                if(bigSh)
                    ret = 0;
                else {
                    // ">>" rounds as floor(), but we want trunc() like "/"
                    ret = (rc < 0)?
                        -(-rc >>> absE) :
                        rc >>> absE;
                }
            } else {
                if(bigSh) {
                    ret = 0;
                    back = 0;
                } else {
                    ret  = rc  << absE;
                    back = ret >> absE;
                }

                if(back != rc)
                    IntFlag.over.raise!throws();
            }
        } else {
            if(exp & ~maxSh)
                ret = (exp < 0)? 0 : left;
            else {
                const mask = ~(~cast(N)0 << exp);
                ret = cast(R)(left < 0?
                    -(-left & mask) :
                     left & mask);
            }
        }

        return ret;
    }
/+}+/

/+pragma(inline, false)+/ // Minimize template bloat by using a common pow() implementation
B powImpl(B, E)(const B base, const E exp, ref IntFlag flag)
    if((is(B == int) || is(B == uint) || is(B == long) || is(B == ulong)) &&
        (is(E == long) || is(E == ulong)))
{
    static if(isSigned!B) {
        alias cmul = muls;
        const smallB = (1 >= base && base >= -1);
    } else {
        alias cmul = mulu;
        const smallB = (base <= 1);
    }

    if(smallB) {
        if(base == 0) {
            static if(isSigned!E) {
                if(exp < 0)
                    flag = IntFlag.div0;
            }

            return (exp == 0);
        }

        return (exp & 0x1)? base : 1;
    }
    if(exp <= 0)
        return (exp == 0);

    B ret = 1;
    if(exp <= precision!B) {
        B b = base;
        int e = cast(int)exp;
        if(e & 0x1)
            ret = b;
        e >>>= 1;

        bool over = false;
        while(e != 0) {
            b = cmul(b, b, over);
            if(e & 0x1)
                ret = cmul(ret, b, over);

            e >>>= 1;
        }

        if(!over)
            return ret;
    }

    flag = (base < 0 && (exp & 0x1))?
        IntFlag.negOver :
        IntFlag.posOver;
    return ret;
}
