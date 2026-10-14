param([string]$AppPath)
$ErrorActionPreference = 'Stop'
if (-not $AppPath) { $AppPath = Join-Path $PSScriptRoot '..\out\SharkOptimizer.Native.exe' }
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Web.Extensions
$assembly = [Reflection.Assembly]::LoadFile([IO.Path]::GetFullPath($AppPath))
$windowType = $assembly.GetType('SharkOptimizer.NativeApp.MainWindow')
$codec = $assembly.GetType('SharkOptimizer.NativeApp.PresetCodec')
$flags = [Reflection.BindingFlags]'Static,NonPublic'
$aliases = $windowType.GetField('LegacyTweakAliases',$flags).GetValue($null)
$definitions = $windowType.GetField('Definitions',$flags).GetValue($null)
$nativeIds = @($definitions | ForEach-Object { $_.GetType().GetField('Id').GetValue($_) })
$map = [Func[string,string]] { param($id) if ($aliases.ContainsKey($id)) { return $aliases[$id] }; if ($nativeIds -contains $id) { return $id }; return $null }
$export = [Func[string,string]] { param($id) foreach ($pair in $aliases.GetEnumerator()) { if ($pair.Value -eq $id) { return $pair.Key } }; return $id }
$json = '{"format":"SharkOptimizerPresets","version":1,"presets":[{"name":"Legacy gaming","ids":["f_gamemode","f_dvr","f_gamemode","unsupported"]}]}'
$list = $codec.GetMethod('ReadJson',$flags).Invoke($null,@($json,$map))
if ($list.Count -ne 1 -or $list[0].Ids.Count -ne 2 -or $list[0].Ids -notcontains 'game-mode') { throw 'Legacy JSON normalization failed.' }
$encoded = $codec.GetMethod('Encode',$flags).Invoke($null,@($list[0],$export))
$decoded = $codec.GetMethod('Decode',$flags).Invoke($null,@($encoded,$map))
if ($decoded.Name -ne 'Legacy gaming' -or $decoded.Ids.Count -ne 2) { throw 'Share-code round-trip failed.' }
$b64 = $encoded.Substring(7).Replace('-','+').Replace('_','/'); while ($b64.Length % 4) { $b64 += '=' }
$memory = New-Object IO.MemoryStream (,[Convert]::FromBase64String($b64))
$deflate = New-Object IO.Compression.DeflateStream $memory,([IO.Compression.CompressionMode]::Decompress)
$reader = New-Object IO.StreamReader $deflate,([Text.Encoding]::UTF8)
try { $legacyPayload = $reader.ReadToEnd() } finally { $reader.Dispose(); $memory.Dispose() }
if ($legacyPayload -notmatch '^Legacy gaming\|f_dvr,f_gamemode$') { throw ('Legacy payload mismatch: ' + $legacyPayload) }
$allAliases = '{"presets":[{"name":"All legacy tweaks","ids":' + (ConvertTo-Json -InputObject @($aliases.Keys) -Compress) + '}]}'
$allPresets = $codec.GetMethod('ReadJson',$flags).Invoke($null,@($allAliases,$map))
if ($allPresets[0].Ids.Count -ne (@($aliases.Values | Select-Object -Unique)).Count) { throw 'Not all legacy aliases normalized.' }
$exportJson = $codec.GetMethod('WriteJson',$flags).Invoke($null,@($list,$export))
$readBack = $codec.GetMethod('ReadJson',$flags).Invoke($null,@($exportJson,$map))
if ($readBack[0].Ids.Count -ne 2) { throw 'JSON export/import round-trip failed.' }
$stateType = $assembly.GetType('SharkOptimizer.NativeApp.AppState')
$state = [Activator]::CreateInstance($stateType)
$state.SavedPresets = $list
$serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$restored = $serializer.Deserialize($serializer.Serialize($state), $stateType)
if ($restored.SavedPresets.Count -ne 1 -or $restored.SavedPresets[0].Ids.Count -ne 2) { throw 'Saved preset state round-trip failed.' }
$rejected = 0
foreach ($bad in @('SHARK1-?', 'SHARK1-A', 'invalid')) { try { $null = $codec.GetMethod('Decode',$flags).Invoke($null,@($bad,$map)) } catch { $rejected++ } }
if ($rejected -ne 3) { throw 'Malformed share codes were accepted.' }
$largeMemory = New-Object IO.MemoryStream
$compress = New-Object IO.Compression.DeflateStream $largeMemory,([IO.Compression.CompressionMode]::Compress),$true
$bytes = [Text.Encoding]::UTF8.GetBytes(('X' * 9000) + '|f_gamemode')
$compress.Write($bytes,0,$bytes.Length); $compress.Dispose()
$largeCode = 'SHARK1-' + [Convert]::ToBase64String($largeMemory.ToArray()).TrimEnd('=').Replace('+','-').Replace('/','_'); $largeMemory.Dispose()
$rejectedLarge = $false
try { $null = $codec.GetMethod('Decode',$flags).Invoke($null,@($largeCode,$map)) } catch { $rejectedLarge = $true }
if (!$rejectedLarge) { throw 'Oversized decompressed code was accepted.' }
'Legacy JSON, all legacy IDs, native export/import, SHARK1 compatibility, malformed input, and decompression limits passed.'
