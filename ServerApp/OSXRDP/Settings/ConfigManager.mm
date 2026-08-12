
#include "ConfigManager.h"

static ConfigManager g_ConfigManager;

ConfigManager* ConfigManager::Instance()
{
    return &g_ConfigManager;
}

bool ConfigManager::GetBooleanValue(NSString* key)
{
    return [[NSUserDefaults standardUserDefaults] boolForKey:key];
}

void ConfigManager::SetBooleanValue(NSString* key, BOOL value)
{
    [[NSUserDefaults standardUserDefaults] setBool:value forKey:key];
}
