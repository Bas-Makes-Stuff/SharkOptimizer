param([string]$AppPath)
$ErrorActionPreference='Stop'
if(!$AppPath){$AppPath=Join-Path $PSScriptRoot '..\out\SharkOptimizer.Native.exe'}
Add-Type -AssemblyName PresentationFramework
[Environment]::CurrentDirectory=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$assembly=[Reflection.Assembly]::LoadFile([IO.Path]::GetFullPath($AppPath))
$type=$assembly.GetType('SharkOptimizer.NativeApp.MainWindow');$static=[Reflection.BindingFlags]'Static,NonPublic';$instance=[Reflection.BindingFlags]'Instance,NonPublic'
$definitions=$type.GetField('Definitions',$static).GetValue($null)
$expected=@(
 @('game-capture','AllowGameDVR','LocalMachine',0),
 @('activity-history','EnableActivityFeed','LocalMachine',0),
 @('activity-history','PublishUserActivities','LocalMachine',0),
 @('activity-history','UploadUserActivities','LocalMachine',0),
 @('clipboard-sync','AllowCrossDeviceClipboard','LocalMachine',0),
 @('disable-cortana-cloud-search','AllowCortana','LocalMachine',0),
 @('disable-cortana-cloud-search','AllowCloudSearch','LocalMachine',0),
 @('disable-consumer-suggestions','DisableWindowsConsumerFeatures','LocalMachine',1),
 @('disable-consumer-suggestions','DisableSoftLanding','LocalMachine',1),
 @('disable-consumer-suggestions','DisableWindowsSpotlightFeatures','CurrentUser',1),
 @('disable-update-sharing','DODownloadMode','LocalMachine',0),
 @('disable-onedrive-policy','DisableFileSyncNGSC','LocalMachine',1),
 @('limit-background-apps','LetAppsRunInBackground','LocalMachine',2),
 @('disable-windows-ai-capture','DisableAIDataAnalysis','CurrentUser',1)
)
foreach($rule in $expected){
 $definition=@($definitions|Where-Object{$_.Id -eq $rule[0]})[0]
 $targets=@($definition.Targets|Where-Object{$_.Name -eq $rule[1]})
 if($targets.Count -ne 1 -or [string]$targets[0].Hive -ne $rule[2] -or $targets[0].Value -ne $rule[3] -or [string]$targets[0].Kind -ne 'DWord'){throw ('Wrong policy target: '+$rule[0]+'/'+$rule[1])}
}
$ads=@($definitions|Where-Object{$_.Id -eq 'remove-windows-ads'})[0]
foreach($name in @('SubscribedContent-338387Enabled','SubscribedContent-338388Enabled','SubscribedContent-338389Enabled','SubscribedContent-338393Enabled','SubscribedContent-353694Enabled','SubscribedContent-353696Enabled','SubscribedContent-310093Enabled','SystemPaneSuggestionsEnabled','SoftLandingEnabled','RotatingLockScreenOverlayEnabled','ContentDeliveryAllowed','OemPreInstalledAppsEnabled','PreInstalledAppsEnabled','SilentInstalledAppsEnabled')){
 if(@($ads.Targets|Where-Object{$_.Name -eq $name -and [string]$_.Hive -eq 'CurrentUser' -and $_.Value -eq 0}).Count -ne 1){throw ('Missing promotional-content flag: '+$name)}
}
$window=$type.GetConstructor($instance,$null,[Type[]]@([bool]),$null).Invoke(@($true))
try {
 $definition=@($definitions|Where-Object{$_.Id -eq 'activity-history'})[0]
 $notes=$type.GetMethod('TweakWarningForReview',$instance).Invoke($window,@($definition.PSObject.BaseObject))
 if(!$notes.Contains('all Windows accounts')){throw 'Machine policy has no scope warning before Apply.'}
 if($type.GetField('_state',$instance).GetValue($window).Applied.Count -ne 0){throw 'Inspecting policy definitions changed undo history.'}
 'PASS: Fourteen policy target scopes/values, fourteen promotional-content flags, and machine-policy review warning. No policy values were written.'
} finally {$window.Close()}
