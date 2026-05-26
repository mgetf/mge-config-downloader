#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <ripext>
#include <mge>

#define PLUGIN_VERSION "1.2"

ConVar g_cvEnabled;
ConVar g_cvUrl;
ConVar g_cvNotify;

char g_sPendingMap[PLATFORM_MAX_PATH];
char g_sPendingPath[PLATFORM_MAX_PATH];
bool g_bDownloadInProgress;

public Plugin myinfo =
{
    name        = "MGE Config Auto-Downloader",
    author      = "ampere",
    description = "Downloads missing MGE map configs on-demand from GitHub",
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
        GetCurrentMap(mapName, sizeof(mapName));

    char configPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, configPath, sizeof(configPath), "configs/mge/%s.cfg", mapName);

    if (FileExists(configPath))
    {
        DeleteFile(configPath);
        LogMessage("Deleted existing config for '%s' (forced redownload by %L)", mapName, client);
    }

    ReplyToCommand(client, "[MGE] Redownloading config for %s...", mapName);
    StartDownload(mapName, configPath);
    return Plugin_Handled;
}

public Action MGE_OnMapConfigMissing(const char[] mapName, const char[] configPath)
{
    if (!g_cvEnabled.BoolValue)
        return Plugin_Continue;

    if (g_bDownloadInProgress)
    {
        LogError("Download already in progress, cannot handle missing config for '%s'.", mapName);
        return Plugin_Continue;
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

    if (g_bDownloadInProgress)
    {
        LogError("Download already in progress, cannot handle invalid config for '%s'.", mapName);
        return Plugin_Continue;
    }

    LogMessage("Config for '%s' failed to parse, deleting and redownloading.", mapName);

    if (FileExists(configPath))
        DeleteFile(configPath);

    if (g_cvNotify.BoolValue)
        PrintToChatAll("[SM] Config for map %s is invalid, redownloading...", mapName);

    StartDownload(mapName, configPath);
    return Plugin_Handled;
}

void StartDownload(const char[] mapName, const char[] configPath)
{
    strcopy(g_sPendingMap, sizeof(g_sPendingMap), mapName);
    strcopy(g_sPendingPath, sizeof(g_sPendingPath), configPath);
    g_bDownloadInProgress = true;

    char sUrlTemplate[512];
    g_cvUrl.GetString(sUrlTemplate, sizeof(sUrlTemplate));

    char sUrl[512];
    Format(sUrl, sizeof(sUrl), sUrlTemplate, mapName);

    LogMessage("Attempting to download config for map '%s' from: %s", mapName, sUrl);

    HTTPRequest hRequest = new HTTPRequest(sUrl);
    hRequest.DownloadFile(configPath, OnDownloadComplete);
}

void OnDownloadComplete(HTTPStatus status, any value)
{
    g_bDownloadInProgress = false;

    if (status != HTTPStatus_OK)
    {
        LogError("Failed to download config for map '%s' (HTTP status: %d)", g_sPendingMap, status);
        if (FileExists(g_sPendingPath))
            DeleteFile(g_sPendingPath);
        if (g_cvNotify.BoolValue)
            PrintToChatAll("[SM] Failed to download config for %s (status %d) - map not supported.", g_sPendingMap, status);
        if (GetFeatureStatus(FeatureType_Native, "MGE_ReportConfigUnavailable") == FeatureStatus_Available)
            MGE_ReportConfigUnavailable();
        return;
    }

    int iSize = FileSize(g_sPendingPath);
    if (iSize < 64 || iSize > 1048576)
    {
        LogError("Downloaded config for map '%s' has invalid size (%d bytes) - likely a 404 page, discarding.", g_sPendingMap, iSize);
        DeleteFile(g_sPendingPath);
        if (g_cvNotify.BoolValue)
            PrintToChatAll("[SM] Invalid config downloaded for %s - map not supported.", g_sPendingMap);
        if (GetFeatureStatus(FeatureType_Native, "MGE_ReportConfigUnavailable") == FeatureStatus_Available)
            MGE_ReportConfigUnavailable();
        return;
    }

    KeyValues kv = new KeyValues("SpawnConfigs");
    bool bParsed = kv.ImportFromFile(g_sPendingPath);
    bool bHasArenas = bParsed && kv.GotoFirstSubKey();
    delete kv;

    if (!bParsed || !bHasArenas)
    {
        LogError("Downloaded config for map '%s' is malformed (parsed=%d, hasArenas=%d) - discarding.", g_sPendingMap, bParsed, bHasArenas);
        DeleteFile(g_sPendingPath);
        if (g_cvNotify.BoolValue)
            PrintToChatAll("[SM] Downloaded config for %s is malformed - map not supported.", g_sPendingMap);
        if (GetFeatureStatus(FeatureType_Native, "MGE_ReportConfigUnavailable") == FeatureStatus_Available)
            MGE_ReportConfigUnavailable();
        return;
    }

    LogMessage("Successfully downloaded config for map '%s' (%d bytes). Reloading map.", g_sPendingMap, iSize);
    if (g_cvNotify.BoolValue)
        PrintToChatAll("[SM] Config downloaded for %s! Reloading map...", g_sPendingMap);

    CreateTimer(1.5, Timer_ReloadMap);
}

Action Timer_ReloadMap(Handle hTimer)
{
    ServerCommand("changelevel %s", g_sPendingMap);
    return Plugin_Stop;
}
