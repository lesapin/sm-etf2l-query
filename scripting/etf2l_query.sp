#include <sourcemod>
#include <dbi>
#include <etf2l_query>
#include <system2>
#include <smjansson>

#pragma newdecls required

#define PLUGIN_VERSION "1.0.0"

public Plugin myinfo =
{
    name = "ETF2L Player Query",
    author = "bezdmn",
    description = "Query player information from the ETF2L API",
    version = PLUGIN_VERSION,
    url = ""
};

#define API_ENDPOINT "api-v2.etf2l.org/player/"
#define SQL_CONF "etf2l"

Database db;
DBStatement InsertNewPlayerStmt = null;
DBStatement UpdatePlayerStmt = null;
DBStatement PlayerExistsStmt = null;
DBStatement PlayerIsActiveStmt = null;
DBStatement SetPlayerActiveStmt = null;

public void OnPluginStart()
{
    PrepareSQL();

    RegServerCmd("etf2l_query", ServerETF2LQuery);
    RegServerCmd("etf2l_query_create_db", CreateSQLite);
}

any Native_ActiveETF2LParticipant(Handle plugin, int numParams)
{
    char steamid[64];
    GetNativeString(1, steamid, sizeof(steamid));
    return PlayerIsActive(steamid);
}

any Native_ActiveETF2LBan(Handle plugin, int numParams)
{
    char steamid[64];
    GetNativeString(1, steamid, sizeof(steamid));
    return PlayerIsBanned(steamid);
}

/**************************/
/** System2 HTTP Queries **/
/**************************/

any Native_ETF2LQuery(Handle plugin, int numParams)
{
    char url[128] = API_ENDPOINT;
    char steamid[64];
    GetNativeString(1, steamid, sizeof(steamid));

    StrCat(url, sizeof(url), steamid);
    System2HTTPRequest httpReq = new System2HTTPRequest(HttpPlayerCallback, url);
    httpReq.Timeout = 10;
    httpReq.GET();
    delete httpReq;

    if (PlayerExists(steamid))
    {
        if (!PlayerIsActive(steamid)) // has the player participated in a match since last attempt
        {
            StrCat(url, sizeof(url), "/results");
            System2HTTPRequest resultReq = new System2HTTPRequest(HttpResultsCallback, url);
            resultReq.Timeout = 10;
            resultReq.SetData(steamid); 
            resultReq.GET();
            delete resultReq;
        }

        return true;
    }

    return false;
}

public Action ServerETF2LQuery(int args)
{
    if (args != 1)
    {
        PrintToServer("usage: etf2l_query <steamid>");
        return Plugin_Handled;
    }

    char url[128] = API_ENDPOINT;
    char steamid[64];
    GetCmdArg(1, steamid, sizeof(steamid));

    StrCat(url, sizeof(url), steamid);
    System2HTTPRequest httpReq = new System2HTTPRequest(HttpPlayerCallback, url);
    httpReq.Timeout = 10;
    httpReq.GET();
    delete httpReq;

    if (PlayerExists(steamid))
    {
        if (!PlayerIsActive(steamid)) // check if the player has become active
        {
            StrCat(url, sizeof(url), "/results");
            System2HTTPRequest resultReq = new System2HTTPRequest(HttpResultsCallback, url);
            resultReq.Timeout = 10;
            resultReq.SetData(steamid); 
            resultReq.GET();
            delete resultReq;
        }
    }

    return Plugin_Handled;
}

public void HttpPlayerCallback(bool success, const char[] error, System2HTTPRequest req,
System2HTTPResponse resp, HTTPRequestMethod method)
{
    if (success)
    {
        char[] content = new char[resp.ContentLength + 1];
        resp.GetContent(content, resp.ContentLength + 1);
        
        // prints the response only partially
        PrintToServer("Query response: %s\n", content);

        if (ParseJSON(content))
        {
            PrintToServer("\nJSON response successfully parsed\n");
        }
        else
        {
            PrintToServer("\nCouldn't parse JSON response\n");
        }
    }
}

public void HttpResultsCallback(bool success, const char[] error, System2HTTPRequest req,
System2HTTPResponse resp, HTTPRequestMethod method)
{
    if (success)
    {
        char steamid[64];
        req.GetData(steamid, sizeof(steamid));
    
        // Because the response is usually too long to parse, use content 
        // length as an approximator for player participation. 
        if (resp.ContentLength > 1500)
        {
            PrintToServer("\nPlayer has played in atleast one match\n");
            SetPlayerActive(steamid);
        }
        else
        {
            PrintToServer("\nPlayer is inactive\n");
        }
    }
}

/******************/
/** JSON Parsing **/
/******************/

bool ParseJSON(const char[] jsonStr)
{
    Handle JsonObj = json_load(jsonStr);
    Handle JsonIterator = json_object_iter(JsonObj);
    Handle JsonValue = json_object_iter_value(JsonIterator);

    char JsonKey[32];
    json_object_iter_key(JsonIterator, JsonKey, sizeof(JsonKey));

    if (StrEqual("status", JsonKey))
    {
        if (!StatusOk(JsonValue))
        {
            CloseHandle(JsonObj);
            CloseHandle(JsonIterator);
            CloseHandle(JsonValue);
            return false; 
        }
        else
        {
            JsonIterator = json_object_iter_next(JsonObj, JsonIterator);
            JsonValue = json_object_iter_value(JsonIterator);
            json_object_iter_key(JsonIterator, JsonKey, sizeof(JsonKey));
        }
    }

    if (StrEqual("player", JsonKey))
    {
        ProcessPlayerElement(JsonValue);
    }
    else // unknown element, abort
    {
        CloseHandle(JsonObj);
        CloseHandle(JsonIterator);
        CloseHandle(JsonValue);
        return false;
    }
    
    CloseHandle(JsonObj);
    CloseHandle(JsonIterator);
    CloseHandle(JsonValue);
    return true;
}

bool StatusOk(Handle statusObj)
{
    bool retval = true;

    Handle JsonIterator = json_object_iter(statusObj);
    Handle JsonValue = json_object_iter_value(JsonIterator);
    
    switch(json_integer_value(JsonValue))
    {
        case 200:
        {
            retval = true;
        }
        case 404:
        {
            retval = false;
            PrintToServer("Player profile not found");
        }
    }

    CloseHandle(JsonIterator);
    CloseHandle(JsonValue);

    return retval;
}

void ProcessPlayerElement(Handle playerObj)
{
    int Id = 0;
    int Registered = 0;
    int BanEnd = 0;

    char Country[64];
    char Name[64];
    char TeamName[128];
    char SteamId[64];

    Handle JsonIterator = json_object_iter(playerObj);

    PrintToServer("");

    while (JsonIterator != INVALID_HANDLE)
    {
        char JsonKey[32];
        json_object_iter_key(JsonIterator, JsonKey, sizeof(JsonKey));
        Handle JsonValue = json_object_iter_value(JsonIterator);

        if (StrEqual(JsonKey, "bans") && json_array_size(JsonValue) > 0)
        {
            Handle LatestBanElement = json_array_get(JsonValue, json_array_size(JsonValue) - 1);
            Handle BansJsonIter = json_object_iter(LatestBanElement);
            while (BansJsonIter != INVALID_HANDLE)
            {
                char BansJsonKey[32];
                json_object_iter_key(BansJsonIter, BansJsonKey, sizeof(BansJsonKey));
                Handle BansJsonValue = json_object_iter_value(BansJsonIter);

                if (StrEqual(BansJsonKey, "end"))
                {
                    BanEnd = json_integer_value(BansJsonValue);
                    if (BanEnd < GetTime())
                        BanEnd = 0;
                }

                CloseHandle(BansJsonValue);
                BansJsonIter = json_object_iter_next(LatestBanElement, BansJsonIter);
            }

            PrintToServer("Ban end: %i", BanEnd);
        }
        else if (StrEqual(JsonKey, "country"))
        {
            json_string_value(JsonValue, Country, sizeof(Country));
            PrintToServer("Player country: %s", Country);
        }
        else if (StrEqual(JsonKey, "id"))
        {
            Id = json_integer_value(JsonValue);
            PrintToServer("Player id: %i", Id);
        }
        else if (StrEqual(JsonKey, "name"))
        {
            json_string_value(JsonValue, Name, sizeof(Name));
            PrintToServer("Player name: %s", Name);
        }
        else if (StrEqual(JsonKey, "registered"))
        {
            Registered = json_integer_value(JsonValue);
            PrintToServer("Player registered: %i", Registered);
        }
        else if (StrEqual(JsonKey, "teams"))
        {
            GetTeam(JsonValue, TeamName, sizeof(TeamName));
            PrintToServer("Player team (6v6): %s", TeamName);
        }
        else if (StrEqual(JsonKey, "steam"))
        {
            Handle SteamJsonIter = json_object_iter(JsonValue);
            while (SteamJsonIter != INVALID_HANDLE)
            {
                char SteamJsonKey[32];
                json_object_iter_key(SteamJsonIter, SteamJsonKey, sizeof(SteamJsonKey));
                Handle SteamJsonValue = json_object_iter_value(SteamJsonIter);

                if (StrEqual(SteamJsonKey, "id64"))
                {
                    json_string_value(SteamJsonValue, SteamId, sizeof(SteamId));    
                    PrintToServer("Player SteamId64: %s", SteamId);
                }

                CloseHandle(SteamJsonValue);
                SteamJsonIter = json_object_iter_next(JsonValue, SteamJsonIter);
            }
        }

        CloseHandle(JsonValue);
        JsonIterator = json_object_iter_next(playerObj, JsonIterator);
    }

    if (!PlayerExists(SteamId))
    {
        InsertNewPlayer(SteamId, Name, Country, Id, Registered, 
                        GetTime(), 0, BanEnd, TeamName, GetTime()); 
    }
    else 
    {
        UpdatePlayer(SteamId, BanEnd, TeamName, GetTime());
        if (PlayerIsBanned(SteamId))
            PrintToServer("\nNaughty player!\n");
    }
}

void GetTeam(Handle teamObj, char[] teamName, int nameLen)
{
    for (int iElem = 0; iElem < json_array_size(teamObj); iElem++)
    {
        Handle Team = json_array_get(teamObj, iElem);
        char Name[128], Type[16];

        Handle TeamJsonIter = json_object_iter(Team);
        while (TeamJsonIter != INVALID_HANDLE)
        {
            char TeamJsonKey[32];
            json_object_iter_key(TeamJsonIter, TeamJsonKey, sizeof(TeamJsonKey));
            Handle TeamJsonValue = json_object_iter_value(TeamJsonIter);

            if (StrEqual(TeamJsonKey, "name"))
            {
                json_string_value(TeamJsonValue, Name, sizeof(Name));    
            }
            else if (StrEqual(TeamJsonKey, "type"))
            {
                json_string_value(TeamJsonValue, Type, sizeof(Type));
            }

            CloseHandle(TeamJsonValue);
            TeamJsonIter = json_object_iter_next(Team, TeamJsonIter);
        }

        CloseHandle(Team);

        if (StrEqual(Type, "6v6"))
        {
            strcopy(teamName, nameLen, Name);
            return;
        }
    }
}

/************************/
/** Database Functions **/
/************************/

void PrepareSQL()
{
    if (!SQL_CheckConfig(SQL_CONF))
        SetFailState("No SQL config %s present, aborting", SQL_CONF);

    char err[255];

    db = SQL_Connect(SQL_CONF, true, err, sizeof(err));

    if (db == null)
    {
        SetFailState("Could not connect to ETF2L player database: %s", err);
    }

    PlayerExistsStmt = SQL_PrepareQuery(db, "SELECT EXISTS(SELECT 1 FROM players WHERE steamid=?)",
                                        err, sizeof(err));

    if (PlayerExistsStmt == null)
        LogError("PlayerExistsStmt error");

    PlayerIsActiveStmt = SQL_PrepareQuery(db, "SELECT active FROM players WHERE steamid=?", 
                                        err, sizeof(err));

    if (PlayerIsActiveStmt == null)
        LogError("PlayerIsActiveStmt error");

    InsertNewPlayerStmt = SQL_PrepareQuery(db, "INSERT \
            INTO players \
                (steamid, name, country, id, reg, first, active, ban, team, last) \
            VALUES \
                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", 
            err, sizeof(err));

    if (InsertNewPlayerStmt == null)
        LogError("InsertNewPlayerStmt error");

    SetPlayerActiveStmt = SQL_PrepareQuery(db, "UPDATE players SET active=1 WHERE steamid=?",
                                        err, sizeof(err));
    
    if (SetPlayerActiveStmt == null)
        LogError("SetPlayerActiveStmt error");

    UpdatePlayerStmt = SQL_PrepareQuery(db, "UPDATE players \
                                                SET ban=?, team=?, last=? \
                                             WHERE \
                                                steamid=?",
                                        err, sizeof(err));

    if (UpdatePlayerStmt == null)
        LogError("UpdatePlayerStmt error");

}

public Action CreateSQLite(int args)
{
    DBResultSet q = SQL_Query(db, "CREATE TABLE IF NOT EXISTS players \
        ( \
            steamid TEXT UNIQUE, \
            name    TEXT NOT NULL, \
            country TEXT NOT NULL, \
            id      INTEGER UNIQUE, \
            reg     INTEGER, \
            first   INTEGER, \
            active  INTEGER, \
            ban     INTEGER, \
            team    TEXT, \
            last    INTEGER  \
        )");

    if (q == INVALID_HANDLE)
    {
        SetFailState("Could not create SQLite table");
    }
    else
    {
        PrintToServer("\nTable ETF2L players initialized\n");
    }

    CloseHandle(q);
    return Plugin_Handled;
}

bool PlayerExists(const char[] steamid)
{
    SQL_BindParamString(PlayerExistsStmt, 0, steamid, false);
    if (SQL_Execute(PlayerExistsStmt))
    {
        SQL_FetchRow(PlayerExistsStmt);
        int exists = SQL_FetchInt(PlayerExistsStmt, 0);
        return view_as<bool>(exists);
    }

    return false;
}

bool PlayerIsActive(const char[] steamid)
{
    SQL_BindParamString(PlayerIsActiveStmt, 0, steamid, false);
    if (SQL_Execute(PlayerIsActiveStmt))
    {
        SQL_FetchRow(PlayerIsActiveStmt);
        int active = SQL_FetchInt(PlayerIsActiveStmt, 0);
        return view_as<bool>(active);
    }

    return false;
}

bool PlayerIsBanned(const char[] steamid)
{
    char query[128];
    int ban = 0;
    Format(query, sizeof(query), "SELECT ban FROM players WHERE steamid = '%s'", steamid);
    
    DBResultSet q = SQL_Query(db, query);
    if (q != null)
    {
        SQL_FetchRow(q);
        ban = SQL_FetchInt(q, 0);
    }
    delete q;

    return (ban > 0);
}

void SetPlayerActive(const char[] steamid)
{
    SQL_BindParamString(SetPlayerActiveStmt, 0, steamid, false);
    if (SQL_Execute(SetPlayerActiveStmt))
    {

    }
}

void InsertNewPlayer(const char[] steamid, const char[] name, const char[] country, int id,
                     int reg, int first, int active, int ban, const char[] team, int last)
{
    SQL_BindParamString(InsertNewPlayerStmt, 0, steamid, false);
    SQL_BindParamString(InsertNewPlayerStmt, 1, name, false);
    SQL_BindParamString(InsertNewPlayerStmt, 2, country, false);
    SQL_BindParamInt(InsertNewPlayerStmt, 3, id, false);
    SQL_BindParamInt(InsertNewPlayerStmt, 4, reg, false);
    SQL_BindParamInt(InsertNewPlayerStmt, 5, first, false);
    SQL_BindParamInt(InsertNewPlayerStmt, 6, active, false);
    SQL_BindParamInt(InsertNewPlayerStmt, 7, ban, false);
    SQL_BindParamString(InsertNewPlayerStmt, 8, team, false);
    SQL_BindParamInt(InsertNewPlayerStmt, 9, last, false);

    if (SQL_Execute(InsertNewPlayerStmt))
    {

    }
}

void UpdatePlayer(const char[] steamid, int ban, const char[] team, int last)
{
    SQL_BindParamInt(UpdatePlayerStmt, 0, ban, false);
    SQL_BindParamString(UpdatePlayerStmt, 1, team, false);
    SQL_BindParamInt(UpdatePlayerStmt, 2, last, false);
    SQL_BindParamString(UpdatePlayerStmt, 3, steamid, false);

    if (SQL_Execute(UpdatePlayerStmt))
    {

    }
}
