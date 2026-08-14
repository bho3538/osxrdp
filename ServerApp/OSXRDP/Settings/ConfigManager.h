
#ifndef ConfigManager_h
#define ConfigManager_h

#import <Foundation/Foundation.h>

#define _ENABLE_DYNAMIC_RESOLUTION        @"advanced.dynamicresolution"
#define _ENABLE_AUDIO                     @"advanced.audio"

#define _CONFIG_ENABLED(key) (ConfigManager::Instance()->GetBooleanValue((key)))

class ConfigManager
{
public:
    ConfigManager() {
        // register default value
        NSDictionary *appDefaults = @{
            _ENABLE_DYNAMIC_RESOLUTION : @NO,
            _ENABLE_AUDIO : @NO
        };

        [[NSUserDefaults standardUserDefaults] registerDefaults:appDefaults];
    }
    
    ~ConfigManager() = default;
    
    static ConfigManager* Instance();
    
    bool GetBooleanValue(NSString* key);
    
    void SetBooleanValue(NSString* key, BOOL value);
    
private:
    
};

#endif
