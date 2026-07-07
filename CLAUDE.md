# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

PowerShell scripts deployed as [SyncroMSP](https://syncromsp.com/) RMM scripts. They run on managed Windows endpoints via SyncroMSP's scripting engine.

## Creating new scripts

Make sure, to update the README.md to keep the list of scripts up-to-date. 

## Deployment Model

Scripts are uploaded directly into SyncroMSP under **Scripting → Scripts** and run on endpoints. There is no build step or test runner — scripts are validated by reading and reasoning about them.

An alternative deployment pattern (documented in README.md) is to keep a thin SyncroMSP wrapper that downloads and executes the real script from a GitHub raw URL at runtime, so updates take effect without re-uploading to SyncroMSP.

## Script Conventions

- Every script begins with `Import-Module $env:SyncroModule` to load the SyncroMSP API.
- Custom asset fields must be pre-created in SyncroMSP (**Admin → Custom Asset Fields**) before a script can write to them. Use `Set-Asset-Field -Name "<field>" -Value <value>` to write.
- Use `Rmm-Alert -Category "<name>" -Body "<message>"` to raise alerts visible in SyncroMSP.
- Scripts exit with `exit 0` (success/no issue) or `exit 1` (alert condition met).
- Scripts that are not applicable to a device (e.g., HP-only scripts on non-HP hardware) exit 0 with an explanatory `Write-Host` message.

## Custom Asset Field Requirements

Each script documents the asset fields it needs. See README.md for the field names and expected values per script. Creating the wrong field name or type will silently fail.
