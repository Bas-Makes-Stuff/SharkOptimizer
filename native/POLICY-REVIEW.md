# Policy-target review

The legacy catalogue has 96 built-in IDs and 118 declared registry targets. The native catalogue maps all 96 IDs. Following this review, 111 legacy registry targets match directly; the seven differences below are intentional and reviewed rather than unimplemented options.

| Difference | Native behavior and basis |
| --- | --- |
| Windows Spotlight | Uses HKCU. The installed Microsoft CloudContent.admx declares DisableWindowsSpotlightFeatures as a User policy; the legacy HKLM target was not its declared scope. |
| Recall snapshots | Uses the supported per-user DisableAIDataAnalysis policy. Microsoft's current documentation allows Device and User scope. [WindowsAI policy reference](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-windowsai#disableaidataanalysis). |
| Two app-shutdown timeouts | Uses 3000 ms rather than the legacy 2000 ms. Both shorten waits; the native choice gives unresponsive apps an extra second before shutdown continues. The warning covers unsaved work. |
| Two Edge background policies | Retains the documented per-user native behavior rather than the legacy machine-wide scope. [Configure Edge policies](https://learn.microsoft.com/en-us/deployedge/configure-microsoft-edge), [Startup Boost policy](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/startupboostenabled). |
| Service-host grouping threshold | Computes the threshold from actual physical-memory bytes, with the existing 8 GB requirement and DWORD cap, rather than the legacy rounded-GB fixture value. |

Corrected machine-policy targets include Cortana/cloud search, activity publishing/uploading, cross-device clipboard, consumer suggestions/soft landing, Delivery Optimization, Store background execution, OneDrive sync, and Game DVR. Local Microsoft Search, OSPolicy, CloudContent, DeliveryOptimization, AppPrivacy, and GameDVR ADMX files establish their policy scope. OneDrive's Device policy is documented in the [System policy reference](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-system#disableonedrivefilesync).

The fourteen original per-user promotional-content flags are now included. Machine-wide policy scope appears in Details & cautions and in the Apply review prompt. Existing undo records remain tied to the targets captured when they were applied; this review does not rewrite saved history or apply policies automatically.

`checks/PolicyTargets.Check.ps1` validates fourteen target scopes/values, all fourteen promotional flags, and the review warning without writing policy values. It does not establish that every policy is honored by every Windows edition, build, or managed device.
