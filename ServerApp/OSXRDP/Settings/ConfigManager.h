
#ifndef ConfigManager_h
#define ConfigManager_h

#import <Foundation/Foundation.h>

#define _ENABLE_SHIFT_NEWWINDOW        @"advanced.enableshiftnewwindow"
#define _ENABLE_NETWORK_PATH           @"advanced.enablenetworkpath"
#define _ENABLE_NEWWINDOW_LIKE_WINDOWS @"advanced.enablenewwindowlikewindows"

#define _CONFIG_ENABLED(key) (ConfigManager::Instance()->GetBooleanValue((key)))

class ConfigManager
{
public:
    ConfigManager() = default;
    ~ConfigManager() = default;
    
    static ConfigManager* Instance();
    
    bool GetBooleanValue(NSString* key);
    
    void SetBooleanValue(NSString* key, BOOL value);
    
private:
    
};

#endif
