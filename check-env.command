#!/bin/bash
cd "$(dirname "$0")"
{
 echo "=== env check $(date)"
 sw_vers
 xcode-select -p 2>&1
 swift --version 2>&1
 xcodebuild -version 2>&1
 which lms; lms version 2>&1
 curl -s --max-time 3 http://localhost:1234/api/v0/models 2>&1 | head -c 3000
 echo; curl -s --max-time 3 http://localhost:1234/v1/models | head -c 1500
 echo; ls ~/.lmstudio 2>&1
 ls ~/.lmstudio/server-logs 2>/dev/null | tail -3
 ~/.lmstudio/bin/lms server status --json 2>&1
 sysctl hw.perflevel0.logicalcpu hw.perflevel1.logicalcpu iogpu.wired_limit_mb vm.swapusage kern.memorystatus_vm_pressure_level 2>&1
 cat ~/.lmstudio/.internal/http-server-config.json 2>&1
} > env-check.log 2>&1
echo done >> env-check.log
