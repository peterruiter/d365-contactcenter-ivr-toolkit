# Installation

First time? Use the guided installer. It takes about 20 minutes.

## Guided install

```powershell
cd power-pete-ivr-toolkit
./build/install.ps1
```

The installer walks six steps:

1. **Prerequisites.** Confirms `pac` is present and authenticates to your environment.
2. **Import.** Imports the managed solution and activates plugins.
3. **Configuration.** Prompts for locale, time zone, country code, wait band
   thresholds and whether scheduled callback is on. Writes them to environment variables.
4. **Holidays and message templates.** Loads the national holidays and starter wording.
5. **Queue profiles.** Points you at the app to create them, or offers the bulk script.
6. **Validation.** Runs `pwrp_HealthCheck` and prints the result.

Stop and fix anything that fails at step 6 before you build an agent on top.

Then create the identity your agent connects as, which the installer does not do because
it registers an application in your tenant:

```powershell
./build/New-ApplicationUser.ps1 -EnvironmentUrl https://yourorg.crm4.dynamics.com
```

## Manual install

If you are installing into a locked down environment or through a pipeline:

```powershell
# 1. Import
pac auth create --environment https://yourorg.crm4.dynamics.com
pac solution import --path ./out/PowerPeteIvrToolkitCore_1.0.0_Managed.zip --activate-plugins --publish-changes

# 2. Register the Custom API contract
./build/Register-CustomApis.ps1 -EnvironmentUrl https://yourorg.crm4.dynamics.com

# 3. Set environment variables (see docs/04-configuration.md for the full list)

# 4. Create queue profiles
./build/New-QueueProfiles.ps1 -EnvironmentUrl https://yourorg.crm4.dynamics.com

# 5. The application user an agent authenticates as
./build/New-ApplicationUser.ps1 -EnvironmentUrl https://yourorg.crm4.dynamics.com

# 6. Validate, as yourself and then as the application
./build/Test-Installation.ps1 -EnvironmentUrl https://yourorg.crm4.dynamics.com
./build/Test-Endpoints.ps1 -EnvironmentUrl https://yourorg.crm4.dynamics.com `
    -TenantId <tenant> -ClientId <app> -ClientSecret <secret>
```

Run that last one. As an administrator every endpoint passes whether the security role is
correct or not, so it is the only check that tells you an agent will work.

Custom API definitions live in `build/customapis.json` rather than in solution XML.
That keeps the contract reviewable in a pull request. The registration script is safe
to run repeatedly and updates in place, which preserves the bindings any existing
agent already has.

## Building from source

```powershell
./build/build.ps1 -Version 1.0.0
```

Restores, builds in Release, runs the unit tests and packs both managed and unmanaged
solutions into `./out`. A signing key is generated on first run if you have not supplied
one, because plugin assemblies must be strong named.

**Visual Studio or the Build Tools are required**, not just the .NET SDK. The assembly
merge signs the output, and signing throws `PlatformNotSupportedException` under the
cross platform build host on any operating system. The build finds MSBuild through
`vswhere` and says so plainly if it cannot.

Raise the version on every deployment to a live environment. The sandbox caches a loaded
assembly by version, so updating the content alone leaves the previous build running.

## What a healthy install looks like

```
[PASS] Queues discovered
       379 active queues found.
[PASS] Queue profiles
       6 of 6 voice queues have a pwrp_queueprofile row. 373 non voice queues ignored.
[PASS] Metrics schema
       msdyn_queueextension is readable.
[PASS] Presence schema
       msdyn_agentstatushistory is readable.
[PASS] Scheduled callback config
       Scheduled callback is off.
[PASS] Default locale
       pwrp_DefaultLocale = nl-NL

Installation healthy.
```

## Uninstalling

```powershell
pac solution delete --solution-name PowerPeteIvrToolkitCore
```

Callback requests and IVR outcome rows are deleted with the solution. Export them
first if the client needs the history.

## Next

[Configuration](04-configuration.md). An install with no queue profiles works, but you
lose speakable names, per queue hours and callback settings.
