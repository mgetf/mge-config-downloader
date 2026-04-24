#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <ripext>
#include <mge>

#define PLUGIN_VERSION "1.0.0"

ConVar g_cvEnabled;
ConVar g_cvUrl;
ConVar g_cvNotify;

char g_sPendingMap[PLATFORM_MAX_PATH];
char g_sPendingPath[PLATFORM_MAX_PATH];

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
        "https://raw.githubusercontent.com/mgetf/MGEMod/main/addons/sourcemod/configs/mge/%s.cfg",
        "URL template used to download configs. %%s is replaced with the map name."
    );
    g_cvNotify = CreateConVar(
        "mgemod_autodownload_notify", "1",
        "Print download status messages to all players in chat.",
        FCVAR_NONE, true, 0.0, true, 1.0
    );

    AutoExecConfig(true, "mgemod_config_downloader");
}

public Action MGE_OnMapConfigMissing(const char[] mapName, const char[] configPath)
{
    if (!g_cvEnabled.BoolValue)
        return Plugin_Continue;

    strcopy(g_sPendingMap, sizeof(g_sPendingMap), mapName);
    strcopy(g_sPendingPath, sizeof(g_sPendingPath), configPath);

    char sUrlTemplate[512];
    g_cvUrl.GetString(sUrlTemplate, sizeof(sUrlTemplate));

    char sUrl[512];
    Format(sUrl, sizeof(sUrl), sUrlTemplate, mapName);

    LogMessage("Attempting to download config for map '%s' from: %s", mapName, sUrl);

    HTTPRequest hRequest = new HTTPRequest(sUrl);
    hRequest.DownloadFile(configPath, OnDownloadComplete);

    if (g_cvNotify.BoolValue)
        PrintToChatAll("[SM] Downloading config for map %s...", mapName);

    return Plugin_Handled;
}

void OnDownloadComplete(HTTPStatus status, any value)
{
    if (status != HTTPStatus_OK)
    {
        LogError("Failed to download config for map '%s' (HTTP status: %d)", g_sPendingMap, status);
        if (FileExists(g_sPendingPath))
            DeleteFile(g_sPendingPath);
        if (g_cvNotify.BoolValue)
            PrintToChatAll("[SM] Failed to download config for %s (status %d) - map not supported.", g_sPendingMap, status);
        return;
    }

    int iSize = FileSize(g_sPendingPath);
    if (iSize < 64 || iSize > 1048576)
    {
        LogError("Downloaded config for map '%s' has invalid size (%d bytes) - likely a 404 page, discarding.", g_sPendingMap, iSize);
        DeleteFile(g_sPendingPath);
        if (g_cvNotify.BoolValue)
            PrintToChatAll("[SM] Invalid config downloaded for %s - map not supported.", g_sPendingMap);
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
