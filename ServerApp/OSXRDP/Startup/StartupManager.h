#ifndef StartupManager_h
#define StartupManager_h

class StartupManager
{
public:
  StartupManager() = default;
  ~StartupManager() = default;
  
  static bool IsStartupEnabled();
  
  static bool EnableStartup();
  
  static bool DisableStartup();
  
  static bool IsMacOS13OrHigher();
};

#endif /* StartupManager_h */
