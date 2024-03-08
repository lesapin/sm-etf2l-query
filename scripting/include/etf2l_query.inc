#if defined _etf2l_query_included_
    #endinput
#endif
#define _etf2l_query_included_

#define SQL_CONF "etf2l"

/**
 *  Query ETF2L API for player information and store it in a database.
 * 
 *  @param steamid      SteamID64 of the client.
 *
 *  @return             True if the player has a registerd ETF2L account, false otherwise. 
 */
native bool ETF2LQuery(const char[] steamid);

/**
 *  Check if the player has participated in atleast one ETF2L match.
 *  Should be called after ETF2LQuery when it is known that the player is registered on ETF2L. 
 *
 *  @param steamid      SteamID64 of the client.
 *
 *  @return             True if there is an active participation, false otherwise.
 */
native bool ActiveETF2LParticipant(const char[] steamid);

/**
 *  Check if the player has an active ETF2L ban on their profile.
 *  Should be called after ETF2LQuery when it is known that the player is registered on ETF2L. 
 *
 *  @param steamid      SteamID64 of the client.
 *
 *  @return             True if there is an active ban, false otherwise.
 */
native bool ActiveETF2LBan(const char[] steamid);
