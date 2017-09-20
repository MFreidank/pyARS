# This file is a part of Julia. License is MIT: http://julialang.org/license

module Libc

export FILE, TmStruct, strftime, strptime, getpid, gethostname, free, malloc, calloc, realloc,
    errno, strerror, flush_cstdio, systemsleep, time
@windows_only export GetLastError, FormatMessage

include("errno.jl")

## RawFD ##

# Wrapper for an OS file descriptor (on both Unix and Windows)
immutable RawFD
    fd::Int32
    RawFD(fd::Integer) = new(fd)
    RawFD(fd::RawFD) = fd
end

Base.cconvert(::Type{Int32}, fd::RawFD) = fd.fd

dup(x::RawFD) = RawFD(ccall((@windows? :_dup : :dup),Int32,(Int32,),x.fd))
dup(src::RawFD,target::RawFD) = systemerror("dup",-1==
    ccall((@windows? :_dup2 : :dup2),Int32,
    (Int32,Int32),src.fd,target.fd))

#Wrapper for an OS file descriptor (for Windows)
@windows_only immutable WindowsRawSocket
    handle::Ptr{Void}   # On Windows file descriptors are HANDLE's and 64-bit on 64-bit Windows...
end
@windows_only Base.cconvert(::Type{Ptr{Void}}, fd::WindowsRawSocket) = fd.handle

@unix_only _get_osfhandle(fd::RawFD) = fd
@windows_only _get_osfhandle(fd::RawFD) = WindowsRawSocket(ccall(:_get_osfhandle,Ptr{Void},(Cint,),fd.fd))
@windows_only _get_osfhandle(fd::WindowsRawSocket) = fd

## FILE (not auto-finalized) ##

immutable FILE
    ptr::Ptr{Void}
end

modestr(s::IO) = modestr(isreadable(s), iswritable(s))
modestr(r::Bool, w::Bool) = r ? (w ? "r+" : "r") : (w ? "w" : throw(ArgumentError("neither readable nor writable")))

function FILE(fd::RawFD, mode)
    @unix_only FILEp = ccall(:fdopen, Ptr{Void}, (Cint, Cstring), fd, mode)
    @windows_only FILEp = ccall(:_fdopen, Ptr{Void}, (Cint, Cstring), fd, mode)
    systemerror("fdopen", FILEp == C_NULL)
    FILE(FILEp)
end

function FILE(s::IO)
    f = FILE(dup(RawFD(fd(s))),modestr(s))
    seek(f, position(s))
    f
end

Base.unsafe_convert(T::Union{Type{Ptr{Void}},Type{Ptr{FILE}}}, f::FILE) = convert(T, f.ptr)
Base.close(f::FILE) = systemerror("fclose", ccall(:fclose, Cint, (Ptr{Void},), f.ptr) != 0)
Base.convert(::Type{FILE}, s::IO) = FILE(s)

function Base.seek(h::FILE, offset::Integer)
    systemerror("fseek", ccall(:fseek, Cint, (Ptr{Void}, Clong, Cint),
                               h.ptr, offset, 0) != 0)
    h
end

Base.position(h::FILE) = ccall(:ftell, Clong, (Ptr{Void},), h.ptr)

# flush C stdio output from external libraries
flush_cstdio() = ccall(:jl_flush_cstdio, Void, ())

## time-related functions ##

# TODO: check for usleep errors?
@unix_only systemsleep(s::Real) = ccall(:usleep, Int32, (UInt32,), round(UInt32,s*1e6))
@windows_only systemsleep(s::Real) = (ccall(:Sleep, stdcall, Void, (UInt32,), round(UInt32,s*1e3)); return Int32(0))

type TmStruct
    sec::Int32
    min::Int32
    hour::Int32
    mday::Int32
    month::Int32
    year::Int32
    wday::Int32
    yday::Int32
    isdst::Int32
    # on some platforms the struct is 14 words, even though 9 are specified
    _10::Int32
    _11::Int32
    _12::Int32
    _13::Int32
    _14::Int32

    TmStruct(sec, min, hour, mday, month, year, wday, yday, isdst) =
        new(sec, min, hour, mday, month, year, wday, yday, isdst, 0,0,0,0,0)
    TmStruct() = new(0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    function TmStruct(t::Real)
        t = floor(t)
        tm = TmStruct()
        # TODO: add support for UTC via gmtime_r()
        ccall(:localtime_r, Ptr{TmStruct}, (Ptr{Int}, Ptr{TmStruct}), &t, &tm)
        return tm
    end
end

strftime(t) = strftime("%c", t)
strftime(fmt::AbstractString, t::Real) = strftime(fmt, TmStruct(t))
function strftime(fmt::AbstractString, tm::TmStruct)
    timestr = Array(UInt8, 128)
    n = ccall(:strftime, Int, (Ptr{UInt8}, Int, Cstring, Ptr{TmStruct}),
              timestr, length(timestr), fmt, &tm)
    if n == 0
        return ""
    end
    bytestring(pointer(timestr), n)
end

strptime(timestr::AbstractString) = strptime("%c", timestr)
function strptime(fmt::AbstractString, timestr::AbstractString)
    tm = TmStruct()
    r = ccall(:strptime, Ptr{UInt8}, (Cstring, Cstring, Ptr{TmStruct}),
              timestr, fmt, &tm)
    # the following would tell mktime() that this is a local time, and that
    # it should try to guess the timezone. not sure if/how this should be
    # exposed in the API.
    # tm.isdst = -1
    if r == C_NULL
        #TODO: better error message
        throw(ArgumentError("invalid arguments"))
    end
    @osx_only begin
        # if we didn't explicitly parse the weekday or year day, use mktime
        # to fill them in automatically.
        if !ismatch(r"([^%]|^)%(a|A|j|w|Ow)", fmt)
            ccall(:mktime, Int, (Ptr{TmStruct},), &tm)
        end
    end
    tm
end

# system date in seconds
time(tm::TmStruct) = Float64(ccall(:mktime, Int, (Ptr{TmStruct},), &tm))
time() = ccall(:clock_now, Float64, ())

## process-related functions ##

getpid() = ccall(:jl_getpid, Int32, ())

## network functions ##

function gethostname()
    hn = Array(UInt8, 256)
    @unix_only err=ccall(:gethostname, Int32, (Ptr{UInt8}, UInt), hn, length(hn))
    @windows_only err=ccall(:gethostname, stdcall, Int32, (Ptr{UInt8}, UInt32), hn, length(hn))
    systemerror("gethostname", err != 0)
    bytestring(pointer(hn))
end

## system error handling ##

errno() = ccall(:jl_errno, Cint, ())
errno(e::Integer) = ccall(:jl_set_errno, Void, (Cint,), e)
strerror(e::Integer) = bytestring(ccall(:strerror, Ptr{UInt8}, (Int32,), e))
strerror() = strerror(errno())

@windows_only begin
    @doc """
        GetLastError()

    Call the Win32 `GetLastError` function [only available on Windows].
    """ ->
    GetLastError() = ccall(:GetLastError,stdcall,UInt32,())

    @doc """
        FormatMessage(n=GetLastError())

    Convert a Win32 system call error code to a descriptive string [only available on Windows].
    """ ->
    function FormatMessage(e=GetLastError())
        const FORMAT_MESSAGE_ALLOCATE_BUFFER = UInt32(0x100)
        const FORMAT_MESSAGE_FROM_SYSTEM = UInt32(0x1000)
        const FORMAT_MESSAGE_IGNORE_INSERTS = UInt32(0x200)
        const FORMAT_MESSAGE_MAX_WIDTH_MASK = UInt32(0xFF)
        lpMsgBuf = Array(Ptr{UInt16})
        lpMsgBuf[1] = 0
        len = ccall(:FormatMessageW,stdcall,UInt32,(Cint, Ptr{Void}, Cint, Cint, Ptr{Ptr{UInt16}}, Cint, Ptr{Void}),
                    FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS | FORMAT_MESSAGE_MAX_WIDTH_MASK,
                    C_NULL, e, 0, lpMsgBuf, 0, C_NULL)
        p = lpMsgBuf[1]
        len == 0 && return utf8("")
        len = len + 1
        buf = Array(UInt16, len)
        unsafe_copy!(pointer(buf), p, len)
        ccall(:LocalFree,stdcall,Ptr{Void},(Ptr{Void},),p)
        return utf8(UTF16String(buf))
    end
end

## Memory related ##

free(p::Ptr) = ccall(:free, Void, (Ptr{Void},), p)
malloc(size::Integer) = ccall(:malloc, Ptr{Void}, (Csize_t,), size)
realloc(p::Ptr, size::Integer) = ccall(:realloc, Ptr{Void}, (Ptr{Void}, Csize_t), p, size)
calloc(num::Integer, size::Integer) = ccall(:calloc, Ptr{Void}, (Csize_t, Csize_t), num, size)
free(p::Cstring) = free(convert(Ptr{UInt8}, p))
free(p::Cwstring) = free(convert(Ptr{Cwchar_t}, p))

end # module