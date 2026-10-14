param([string]$AppPath)
$ErrorActionPreference='Stop'
if(!$AppPath){$AppPath=Join-Path $PSScriptRoot '..\out\SharkOptimizer.Native.exe'}
Add-Type -AssemblyName PresentationFramework
$assembly=[Reflection.Assembly]::LoadFile([IO.Path]::GetFullPath($AppPath))
$type=$assembly.GetType('SharkOptimizer.NativeApp.MainWindow'); $flags=[Reflection.BindingFlags]'Instance,NonPublic'
$window=$type.GetConstructor($flags,$null,[Type[]]@([bool]),$null).Invoke(@($true))
$state=$type.GetField('_state',$flags).GetValue($window)
$pages=$type.GetField('_pages',$flags).GetValue($window)
function Buttons($root){if($root -is [Windows.Controls.Button]){$root};foreach($child in [Windows.LogicalTreeHelper]::GetChildren($root)){if($child -is [Windows.DependencyObject]){Buttons $child}}}
function Texts($root){if($root -is [Windows.Controls.TextBlock]){$root};foreach($child in [Windows.LogicalTreeHelper]::GetChildren($root)){if($child -is [Windows.DependencyObject]){Texts $child}}}
function Open-Page($route){$null=$type.GetMethod('ShowPage',$flags).Invoke($window,@($route));$window.UpdateLayout()}
function Click-Label($route,$label){$button=@(Buttons $pages[$route] | Where-Object{[string]$_.Content -eq $label -and $_.IsVisible})[0];if(!$button){throw ('Visible button missing: '+$label)};$button.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Button]::ClickEvent)));$window.UpdateLayout()}
try{
 $window.ShowInTaskbar=$false;$window.ShowActivated=$false;$window.Left=-32000;$window.Top=-32000;$window.Opacity=0;$window.Show();$window.UpdateLayout()
 $nav=$type.GetField('_navButtons',$flags).GetValue($window)
 if($nav.Count -ne 5){throw 'Sidebar did not have five primary routes.'}
 Open-Page 'Tools'
 $opens=@(Buttons $pages['Tools'] | Where-Object{[string]$_.Content -eq 'Open'})
 if($opens.Count -ne 4){throw 'Tools overview did not expose four destinations.'}
 $opens[1].RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Button]::ClickEvent)));$window.UpdateLayout()
 if($pages['Network'].Visibility -ne 'Visible'){throw 'Tool card did not navigate to Network.'}
 Click-Label 'Network' 'Back to tools'
 if($pages['Tools'].Visibility -ne 'Visible'){throw 'Tool back navigation failed.'}
 Open-Page 'Optimize'
 if($type.GetField('_checks',$flags).GetValue($window).Count -ne 3){throw 'Overview did not limit its recommended preview to three tweaks.'}
 Click-Label 'Optimize' 'Show all'
 if($type.GetField('_checks',$flags).GetValue($window).Count -le 3){throw 'Show all did not open the complete category.'}
 $results=$type.GetField('_existingTweakResults',$flags).GetValue($window);$results['game-mode']=$true
 $null=$type.GetMethod('RenderTweakCards',$flags).Invoke($window,@());$window.UpdateLayout()
 $check=@($type.GetField('_checks',$flags).GetValue($window) | Where-Object{$_.Tag.Id -eq 'game-mode'})[0]
 if(!$check -or $check.IsEnabled -or !$check.IsChecked){throw 'External enabled setting was not clearly shown and locked.'}
 $card=$check.Parent;while($card -and $card -isnot [Windows.Controls.Border]){$card=$card.Parent}
 if(!$card -or $card.BorderBrush.Color.R -ne 63 -or $card.BorderBrush.Color.G -ne 177){throw 'Enabled tweak did not have the green border.'}
 Click-Label 'Optimize' 'Presets'
 if(!$type.GetField('_presetsExpander',$flags).GetValue($window).IsVisible){throw 'Presets view stayed hidden.'}
 Click-Label 'Optimize' 'General'
 if($type.GetField('_presetsExpander',$flags).GetValue($window).IsVisible){throw 'Presets stayed on the General page.'}
 Open-Page 'Games';Click-Label 'Games' 'Game Boost'
 if($pages['Game Session'].Visibility -ne 'Visible'){throw 'Games did not expose Game Boost.'}
 Click-Label 'Game Session' 'Profile'
 if(!$type.GetField('_sessionUsePerformancePlan',$flags).GetValue($window).IsVisible -or $type.GetField('_automaticSessionCheck',$flags).GetValue($window).IsVisible){throw 'Profile and Session views were not separated.'}
 $type.GetField('_sessionUsePerformancePlan',$flags).GetValue($window).IsChecked=$true
 $null=$type.GetMethod('SaveSessionProfile',$flags).Invoke($window,@())
 if(!$state.GameSessions.Profiles['_manual'].PowerPlan){throw 'Profile settings did not save in preview state.'}
 Click-Label 'Game Session' 'Apps'
 if(!$type.GetField('_automaticCloseAppsCheck',$flags).GetValue($window).IsVisible){throw 'Automatic close consent was not in Apps.'}
 Click-Label 'Game Session' 'History'
 if(!$type.GetField('_sessionReportsBody',$flags).GetValue($window).IsVisible){throw 'History view was not reachable.'}
 Open-Page 'Boost-Up';Click-Label 'Boost-Up' 'Maintenance'
 if($type.GetField('_cleanupList',$flags).GetValue($window).IsVisible){throw 'Cleanup folders remained visible in Maintenance.'}
 $jobs=$type.GetField('_maintenanceJobs',$flags).GetValue($window); $job=$jobs[0].PSObject.BaseObject; $job.GetType().GetField('Check',$flags).GetValue($job).IsChecked=$true
 if($type.GetMethod('SelectedMaintenanceJobs',$flags).Invoke($window,@($false)).Count -ne 0 -or $type.GetMethod('SelectedCleanupTargets',$flags).Invoke($window,@($true)).Count -ne 0){throw 'A hidden selection leaked into the other cleanup mode.'}
 Click-Label 'Boost-Up' 'History'
 if(!$type.GetField('_cleanupHistoryBody',$flags).GetValue($window).IsVisible){throw 'Cleanup history view did not render.'}
 Open-Page 'Settings';Click-Label 'Settings' 'Restore'
 if($pages['Restore'].Visibility -ne 'Visible'){throw 'Restore was lost from Settings navigation.'}
 if($state.Applied.Count -ne 0 -or $state.SessionPriorities.Count -ne 0){throw 'Navigation applied a system change.'}
 'PASS: Five main routes, tool cards/back navigation, grouped previews/Show all, green enabled borders, presets, Game Boost views, profile controls, cleanup views and Restore access. Preview state only; no system changes.'
}finally{$window.Close()}
