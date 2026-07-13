# Error suppression cleanup plan

## ConvertFrom-Json -ErrorAction SilentlyContinue (REMOVE from 9 occurrences)
- scripts/bump-lockfile.ps1:378
- src/hosts/Windows/modules/system/Sync-JellyfinAccount.ps1:104
- src/hosts/Windows/modules/system/Sync-JellyfinLibrary.ps1:105
- src/hosts/Windows/modules/system/Sync-LiteLLMService.ps1:119
- src/hosts/Windows/modules/system/Sync-CaddyLocalCA.ps1:77
- src/hosts/Windows/modules/system/Sync-CaddyService.ps1:99
- src/hosts/Windows/modules/user/Sync-CamillaDSPService.ps1:61, 158
- src/hosts/Windows/modules/system/Invoke-AISync.ps1:114

## Remove-Item -ErrorAction SilentlyContinue
### cleanup-after-failure → -ErrorAction Ignore + WHY
- src/hosts/Windows/modules/system/Invoke-WingetConfiguration.ps1:105 (finally)
- src/hosts/Windows/modules/system/Invoke-VMSetup.ps1:991, 1343
- src/hosts/Windows/modules/secrets/Get-Secret.ps1:76,108 (already has comment)
- src/hosts/Windows/modules/secrets/Get-DecryptedBlob.ps1:73,106 (already has comment)
- src/hosts/Windows/modules/editors/Sync-VSCodeExtension.ps1:195,199
- src/hosts/Windows/modules/system/Invoke-ReplicaSync.ps1:366,372

### Remove SilentlyContinue (guarded or normal flow)
- src/hosts/Windows/modules/user/Disable-SteamAutoStartup.ps1:42 (guarded by Test-Path)
- src/hosts/Windows/modules/user/Sync-CustomProvisionSymlink.ps1:129,164,196 (guarded by Test-ManagedSymlink)
- src/hosts/Windows/modules/system/Invoke-VMSetup.ps1:535 (guarded by Test-Path)

## Get-Command -ErrorAction SilentlyContinue → ADD WHY comments
- Many files listed in search results

## Get-Service -ErrorAction SilentlyContinue → ADD WHY comments
- Set-NucleusService.ps1:22,52
- Initialize-SSHHostKey.ps1:77
- Sync-LiteLLMService.ps1:72,136
- Sync-GitAndSshConfig.ps1:257
- Sync-OpenSSHServer.ps1:108
- Sync-CloudDrive.ps1:58
- Sync-WindowsRDP.ps1:62

## Get-ItemProperty -ErrorAction SilentlyContinue → ADD WHY comments
- Sync-VSCodeConfig.ps1:107
- Sync-WifiMacRandomization.ps1:48,49,71
- Invoke-WingetConfiguration.ps1:78
- Sync-AgentsSkill.ps1:44
- Sync-PowerPolicy.ps1:109
- Disable-SteamAutoStartup.ps1:31
- Sync-AgentsConfig.ps1:78

## Remove-ItemProperty -ErrorAction SilentlyContinue → ADD WHY comments
- Sync-QtPassConfig.ps1:174
- Disable-SteamAutoStartup.ps1:33

## 2>$null → ADD WHY comments
- Many files listed in search results

## File grouping for subagents:
1. **scripts/ group**: bump-lockfile.ps1, gc.ps1, cloud-setup.ps1, update.ps1, health-check.ps1, gs-pdf-opt.ps1, bootstrap.ps1
2. **system modules group**: All files under src/hosts/Windows/modules/system/
3. **user/secrets/editors/setup modules group**: All other module files
4. **apply.ps1**: src/hosts/Windows/apply.ps1
