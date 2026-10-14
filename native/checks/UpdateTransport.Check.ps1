param([string]$AppPath)
$ErrorActionPreference = 'Stop'
if (!$AppPath) { $AppPath = Join-Path $PSScriptRoot '..\out\SharkOptimizer.Native.exe' }
$assembly = [Reflection.Assembly]::LoadFile([IO.Path]::GetFullPath($AppPath))
$type = $assembly.GetType('SharkOptimizer.NativeApp.UpdateTransport')
$flags = [Reflection.BindingFlags]'Static,NonPublic'
$copy = $type.GetMethod('CopyBounded',$flags)
$validate = $type.GetMethod('ValidateAssetUri',$flags)
foreach ($uri in @('http://github.com/Bas-Makes-Stuff/SharkOptimizer/releases/download/v2.1.2/setup.exe', 'https://example.com/setup.exe', 'https://github.com/other/repo/releases/download/v2.1.2/setup.exe', 'https://github.com/Bas-Makes-Stuff/SharkOptimizer/releases/download/v2.1.2/setup.exe?redirect=1')) {
 $rejected = $false; try { $validate.Invoke($null,@([Uri]$uri)) } catch { $rejected = $true }
 if (!$rejected) { throw ('An unofficial asset URL was accepted: ' + $uri) }
}
$validate.Invoke($null,@([Uri]'https://github.com/Bas-Makes-Stuff/SharkOptimizer/releases/download/v2.1.2/SharkOptimizer-Setup.exe'))
foreach ($limit in @(4,5)) {
 $input = New-Object IO.MemoryStream (,[byte[]]@(1,2,3,4,5)); $output = New-Object IO.MemoryStream
 try {
  $rejected = $false; try { $count = $copy.Invoke($null,@($input.PSObject.BaseObject,$output.PSObject.BaseObject,[long]$limit,[int]30)) } catch { $rejected = $true }
  if (($limit -eq 4) -ne $rejected) { throw 'Streaming byte-limit behavior is wrong.' }
  if ($limit -eq 5 -and ($count -ne 5 -or $output.Length -ne 5)) { throw 'Exact-size transfer failed.' }
 } finally { $input.Dispose(); $output.Dispose() }
}
Add-Type -TypeDefinition @'
using System.IO;
using System.Threading;
public sealed class SlowUpdateCheckStream : MemoryStream {
 public SlowUpdateCheckStream() : base(new byte[] { 1 }) { }
 public override int Read(byte[] buffer, int offset, int count) { Thread.Sleep(1100); return base.Read(buffer, offset, count); }
}
'@
$input = New-Object SlowUpdateCheckStream; $output = New-Object IO.MemoryStream
try {
 $timedOut = $false; try { $copy.Invoke($null,@($input.PSObject.BaseObject,$output.PSObject.BaseObject,[long]1,[int]1)) } catch { $timedOut = $_.Exception.InnerException -is [TimeoutException] }
 if (!$timedOut -or $output.Length -ne 0) { throw 'Expired transfer data was accepted.' }
} finally { $input.Dispose(); $output.Dispose() }
$clientType = $assembly.GetType('SharkOptimizer.NativeApp.UpdateTransport+Client')
$client = [Activator]::CreateInstance($clientType,$true)
try {
 $request = $clientType.GetMethod('GetWebRequest',[Reflection.BindingFlags]'Instance,NonPublic').Invoke($client,@([Uri]'https://api.github.com/repos/Bas-Makes-Stuff/SharkOptimizer/releases/latest'))
 if ($request.Timeout -ne 30000 -or $request.ReadWriteTimeout -ne 15000) { throw 'HTTP request timeouts are missing.' }
} finally { $client.Dispose() }
'PASS: Official-repository asset validation, streaming byte caps, exact-size copying, expired-transfer rejection, and HTTP timeout settings.'
