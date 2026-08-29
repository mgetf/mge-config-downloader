#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <ripext>
#include <mge>

#define PLUGIN_VERSION "1.3"

ConVar g_cvEnabled;
ConVar g_cvSync;
ConVar g_cvUrl;
ConVar g_cvNotify;

char g_sPendingMap[PLATFORM_MAX_PATH];
char g_sPendingDest[PLATFORM_MAX_PATH];
char g_sPendingTemp[PLATFORM_MAX_PATH];
char g_sSkipSyncMap[PLATFORM_MAX_PATH];
bool g_bDownloadInProgress;
bool g_bMgeWaiting;
bool g_bForceReplace;

public Plugin myinfo =
{
    name        = "MGE Config Auto-Downloader",
    author      = "ampere",
    description = "Downloads and keeps MGE map configs in sync with GitHub",
    version     = PLUGIN_VERSION,
    url         = "https://github.com/mgetf/MGEMod"
};

public void OnPluginStart()
{
    g_cvEnabled = CreateConVar(
        "mgemod_autodownload_enabled", "1",
        "Enable automatic downloading of missing MGE map configs.",
        FCVAR_NONE, true, 0.0, true, 1.0
    );
    g_cvSync = CreateConVar(
        "mgemod_autodownload_sync", "1",
        "On each map start, compare the local config against GitHub and replace it if they differ.",
        FCVAR_NONE, true, 0.0, true, 1.0
    );
    g_cvUrl = CreateConVar(
        "mgemod_autodownload_url",
        "https://raw.githubusercontent.com/mgetf/MGEMod/refs/heads/master/addons/sourcemod/configs/mge/%s.cfg",
        "URL template used to download configs. %%s is replaced with the map name."
    );
    g_cvNotify = CreateConVar(
        "mgemod_autodownload_notify", "1",
        "Print download status messages to all players in chat.",
        FCVAR_NONE, true, 0.0, true, 1.0
    );

    RegAdminCmd("sm_mge_config_redownload", Command_RedownloadConfig, ADMFLAG_ROOT,
        "Force redownload of MGE config for a map. Usage: sm_mge_config_redownload [mapname]");

    AutoExecConfig(true, "mgemod_config_downloader");
}

public void OnMapStart()
{
    RequestFrame(Frame_TrySyncCurrentMap);
}

public void OnMapEnd()
{
    g_bMgeWaiting = false;
}

public Action Command_RedownloadConfig(int client, int args)
{
    if (g_bDownloadInProgress)
    {
        ReplyToCommand(client, "[MGE] A config download is already in progress.");
        return Plugin_Handled;
    }

    char mapName[PLATFORM_MAX_PATH];
    if (args >= 1)
        GetCmdArg(1, mapName, sizeof(mapName));
    else
        GetNormalizedMapName(mapName, sizeof(mapName));

    char configPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, configPath, sizeof(configPath), "configs/mge/%s.cfg", mapName);

    g_sSkipSyncMap[0] = '\0';
    g_bForceReplace = true;

    ReplyToCommand(client, "[MGE] Redownloading config for %s...", mapName);
    StartDownload(mapName, configPath);
    return Plugin_Handled;
}

public Action MGE_OnMapConfigMissing(const char[] mapName, const char[] configPath)
{
    if (!g_cvEnabled.BoolValue)
        return Plugin_Continue;

    g_bMgeWaiting = true;

    if (g_bDownloadInProgress)
    {
        LogMessage("Missing config for '%s' - download already in progress, MGE will wait.", mapName);
        return Plugin_Handled;
    }

    if (g_cvNotify.BoolValue)
        PrintToChatAll("[SM] Downloading config for map %s...", mapName);

    StartDownload(mapName, configPath);
    return Plugin_Handled;
}

public Action MGE_OnMapConfigInvalid(const char[] mapName, const char[] configPath)
{
    if (!g_cvEnabled.BoolValue)
        return Plugin_Continue;

    g_bMgeWaiting = true;

    if (g_bDownloadInProgress)
    {
        LogMessage("Invalid config for '%s' - download already in progress, MGE will wait.", mapName);
        return Plugin_Handled;
    }

    LogMessage("Config for '%s' failed to parse, redownloading without deleting the local file yet.", mapName);

    if (g_cvNotify.BoolValue)
        PrintToChatAll("[SM] Config for map %s is invalid, redownloading...", mapName);

    StartDownload(mapName, configPath);
    return Plugin_Handled;
}

void Frame_TrySyncCurrentMap(any data)
{
    if (!g_cvEnabled.BoolValue || !g_cvSync.BoolValue)
        return;

    if (g_bDownloadInProgress)
        return;

    char mapName[PLATFORM_MAX_PATH];
    GetNormalizedMapName(mapName, sizeof(mapName));
    if (mapName[0] == '\0')
        return;

    if (StrEqual(g_sSkipSyncMap, mapName))
    {
        LogMessage("Skipping GitHub sync for '%s' (config was just installed).", mapName);
        g_sSkipSyncMap[0] = '\0';
        return;
    }

    char configPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, configPath, sizeof(configPath), "configs/mge/%s.cfg", mapName);

    LogMessage("Syncing MGE config for '%s' against GitHub.", mapName);
    StartDownload(mapName, configPath);
}

void StartDownload(const char[] mapName, const char[] configPath)
{
    strcopy(g_sPendingMap, sizeof(g_sPendingMap), mapName);
    strcopy(g_sPendingDest, sizeof(g_sPendingDest), configPath);
    Format(g_sPendingTemp, sizeof(g_sPendingTemp), "%s.tmp", configPath);
    g_bDownloadInProgress = true;

    if (FileExists(g_sPendingTemp))
        DeleteFile(g_sPendingTemp);

    char sUrlTemplate[512];
    g_cvUrl.GetString(sUrlTemplate, sizeof(sUrlTemplate));

    char sUrl[512];
    Format(sUrl, sizeof(sUrl), sUrlTemplate, mapName);

    LogMessage("Attempting to download config for map '%s' from: %s", mapName, sUrl);

    HTTPRequest hRequest = new HTTPRequest(sUrl);
    hRequest.DownloadFile(g_sPendingTemp, OnDownloadComplete);
}

void OnDownloadComplete(HTTPStatus status, any value)
{
    g_bDownloadInProgress = false;
    bool forceReplace = g_bForceReplace;
    g_bForceReplace = false;

    if (status != HTTPStatus_OK)
    {
        LogError("Failed to download config for map '%s' (HTTP status: %d)", g_sPendingMap, status);
        DiscardTemp();
        HandleDownloadFailure();
        return;
    }

    if (!IsDownloadedConfigValid(g_sPendingTemp))
    {
        DiscardTemp();
        HandleDownloadFailure();
        return;
    }

    bool hasLocal = FileExists(g_sPendingDest);
    if (hasLocal && !forceReplace && FilesAreIdentical(g_sPendingTemp, g_sPendingDest))
    {
        LogMessage("Local config for '%s' already matches GitHub (%d bytes).", g_sPendingMap, FileSize(g_sPendingDest));
        DiscardTemp();
        return;
    }

    if (!InstallDownloadedConfig(g_sPendingTemp, g_sPendingDest))
    {
        if (FileExists(g_sPendingDest) || !FileExists(g_sPendingTemp))
            DiscardTemp();
        else
            LogError("New config for '%s' is still at %s after a failed install.", g_sPendingMap, g_sPendingTemp);

        HandleDownloadFailure();
        return;
    }

    int iSize = FileSize(g_sPendingDest);
    LogMessage("Installed config for map '%s' (%d bytes) from GitHub.", g_sPendingMap, iSize);

    char currentMap[PLATFORM_MAX_PATH];
    GetNormalizedMapName(currentMap, sizeof(currentMap));
    if (!StrEqual(currentMap, g_sPendingMap))
    {
        LogMessage("Config for '%s' was updated but the server is now on '%s', not reloading.", g_sPendingMap, currentMap);
        return;
    }

    strcopy(g_sSkipSyncMap, sizeof(g_sSkipSyncMap), g_sPendingMap);

    if (g_cvNotify.BoolValue)
    {
        if (hasLocal && !forceReplace)
            PrintToChatAll("[SM] Config for %s changed on GitHub. Reloading map...", g_sPendingMap);
        else
            PrintToChatAll("[SM] Config downloaded for %s! Reloading map...", g_sPendingMap);
    }

    CreateTimer(1.5, Timer_ReloadMap, _, TIMER_FLAG_NO_MAPCHANGE);
}

void HandleDownloadFailure()
{
    if (g_bMgeWaiting)
    {
        if (g_cvNotify.BoolValue)
            PrintToChatAll("[SM] Failed to download config for %s - map not supported.", g_sPendingMap);

        if (GetFeatureStatus(FeatureType_Native, "MGE_ReportConfigUnavailable") == FeatureStatus_Available)
            MGE_ReportConfigUnavailable();
    }
    else
    {
        LogMessage("GitHub sync failed for '%s' - keeping the local config if one exists.", g_sPendingMap);
    }

    g_bMgeWaiting = false;
}

bool IsDownloadedConfigValid(const char[] path)
{
    int iSize = FileSize(path);
    if (iSize < 64 || iSize > 1048576)
    {
        LogError("Downloaded config for map '%s' has invalid size (%d bytes) - discarding.", g_sPendingMap, iSize);
        return false;
    }

    KeyValues kv = new KeyValues("SpawnConfigs");
    bool bParsed = kv.ImportFromFile(path);
    bool bHasArenas = bParsed && kv.GotoFirstSubKey();
    delete kv;

    if (!bParsed || !bHasArenas)
    {
        LogError("Downloaded config for map '%s' is malformed (parsed=%d, hasArenas=%d) - discarding.", g_sPendingMap, bParsed, bHasArenas);
        return false;
    }

    return true;
}

bool InstallDownloadedConfig(const char[] tmpPath, const char[] destPath)
{
    char backupPath[PLATFORM_MAX_PATH];
    Format(backupPath, sizeof(backupPath), "%s.bak", destPath);

    if (FileExists(backupPath))
        DeleteFile(backupPath);

    if (FileExists(destPath) && !RenameFile(backupPath, destPath))
    {
        LogError("Failed to backup old config for '%s' at %s", g_sPendingMap, destPath);
        return false;
    }

    if (!RenameFile(destPath, tmpPath))
    {
        LogError("Failed to move downloaded config for '%s' into place (%s -> %s)", g_sPendingMap, tmpPath, destPath);
        if (FileExists(backupPath))
            RenameFile(destPath, backupPath);
        return false;
    }

    if (FileExists(backupPath))
        DeleteFile(backupPath);

    return true;
}

bool FilesAreIdentical(const char[] pathA, const char[] pathB)
{
    int sizeA = FileSize(pathA);
    int sizeB = FileSize(pathB);
    if (sizeA != sizeB || sizeA < 0)
        return false;

    File fa = OpenFile(pathA, "rb");
    File fb = OpenFile(pathB, "rb");
    if (fa == null || fb == null)
    {
        delete fa;
        delete fb;
        return false;
    }

    int bufA[256];
    int bufB[256];
    int remaining = sizeA;
    bool identical = true;

    while (remaining > 0)
    {
        int toRead = sizeof(bufA);
        if (toRead > remaining)
            toRead = remaining;

        int nA = fa.Read(bufA, toRead, 1);
        int nB = fb.Read(bufB, toRead, 1);
        if (nA != nB || nA <= 0)
        {
            identical = false;
            break;
        }

        for (int i = 0; i < nA; i++)
        {
            if (bufA[i] != bufB[i])
            {
                identical = false;
                break;
            }
        }

        if (!identical)
            break;

        remaining -= nA;
    }

    delete fa;
    delete fb;
    return identical;
}

void DiscardTemp()
{
    if (g_sPendingTemp[0] != '\0' && FileExists(g_sPendingTemp))
        DeleteFile(g_sPendingTemp);
}

void GetNormalizedMapName(char[] buffer, int maxlen)
{
    GetCurrentMap(buffer, maxlen);
    if (StrContains(buffer, "workshop/", false) != -1)
    {
        char pretty[PLATFORM_MAX_PATH];
        if (GetMapDisplayName(buffer, pretty, sizeof(pretty)))
            strcopy(buffer, maxlen, pretty);
    }
}

Action Timer_ReloadMap(Handle hTimer)
{
    char currentMap[PLATFORM_MAX_PATH];
    GetNormalizedMapName(currentMap, sizeof(currentMap));
    if (!StrEqual(currentMap, g_sPendingMap))
    {
        LogMessage("Skipping changelevel for '%s' because the current map is '%s'.", g_sPendingMap, currentMap);
        return Plugin_Stop;
    }

    ServerCommand("changelevel %s", g_sPendingMap);
    return Plugin_Stop;
}
