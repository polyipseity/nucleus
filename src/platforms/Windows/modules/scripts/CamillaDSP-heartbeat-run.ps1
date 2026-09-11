# CamillaDSP heartbeat wrapper PowerShell script.
# Written to disk by Sync-CamillaDSPHeartbeatService.ps1 with tokens replaced by
# actual values.
#
# WHY: a scheduled task action cannot redirect a process's streams, so the task
# launches this wrapper instead of camilladsp-heartbeat.ps1 directly. Without it
# the heartbeat's output went nowhere and its declared log directory was never
# written, so heartbeat failures left no trace on Windows.
# WHY: stdout and stderr go to separate files. logging.capture selects WHICH streams are
# captured, never the destination shape; the house default is the stdout.log/stderr.log pair.
& '__HEARTBEAT_SCRIPT__' -Port __PORT__ -ConfigFile '__CONFIG_FILE__' 1>> '__STDOUT_LOG__' 2>> '__STDERR_LOG__'
