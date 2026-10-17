param(
    [string]$BalatroPath = "G:\SteamLibrary\steamapps\common\Balatro",
    [string]$Pattern = "*_spec.lua"
)

$ErrorActionPreference = "Stop"

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class Lua51 {
    [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool SetDllDirectory(string path);

    [DllImport("lua51.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr luaL_newstate();

    [DllImport("lua51.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern void luaL_openlibs(IntPtr state);

    [DllImport("lua51.dll", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
    public static extern int luaL_loadfile(IntPtr state, string path);

    [DllImport("lua51.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern int lua_pcall(IntPtr state, int nargs, int nresults, int errorFunction);

    [DllImport("lua51.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr lua_tolstring(IntPtr state, int index, out UIntPtr length);

    [DllImport("lua51.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern void lua_close(IntPtr state);
}
'@

if (-not [Lua51]::SetDllDirectory($BalatroPath)) {
    throw "Could not add the Balatro directory to the DLL search path: $BalatroPath"
}

function Get-LuaError([IntPtr]$State) {
    $length = [UIntPtr]::Zero
    $pointer = [Lua51]::lua_tolstring($State, -1, [ref]$length)
    if ($pointer -eq [IntPtr]::Zero) { return "unknown Lua error" }
    return [Runtime.InteropServices.Marshal]::PtrToStringAnsi($pointer, [int]$length.ToUInt64())
}

$specs = Get-ChildItem -Path (Join-Path $PSScriptRoot $Pattern) | Sort-Object Name
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    foreach ($spec in $specs) {
        $state = [Lua51]::luaL_newstate()
        if ($state -eq [IntPtr]::Zero) { throw "luaL_newstate failed" }
        try {
            [Lua51]::luaL_openlibs($state)
            $relativePath = "tests/" + $spec.Name
            $status = [Lua51]::luaL_loadfile($state, $relativePath)
            if ($status -eq 0) { $status = [Lua51]::lua_pcall($state, 0, 0, 0) }
            if ($status -ne 0) { throw "$relativePath`: $(Get-LuaError $state)" }
            Write-Host "$($spec.Name): passed"
        }
        finally {
            [Lua51]::lua_close($state)
        }
    }
}
finally {
    Pop-Location
}

Write-Host "$($specs.Count) specs passed"
