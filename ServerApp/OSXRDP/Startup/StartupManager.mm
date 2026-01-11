#include "StartupManager.h"

#import <ServiceManagement/ServiceManagement.h>

bool StartupManager::IsStartupEnabled()
{
  if (@available(macOS 13.0, *))
  {
    auto status = [SMAppService mainAppService].status;
    
    if (status == SMAppServiceStatusEnabled)
    {
      return true;
    }
    
    return false;
  }
  
  return false;
}

bool StartupManager::EnableStartup()
{
  if (@available(macOS 13.0, *))
  {
    NSError* err = nil;
    
    BOOL re = [[SMAppService mainAppService] registerAndReturnError: &err];
    if (re != NO || err != nil)
    {
      return false;
    }
    
    return true;
  }
  
  return false;
}

bool StartupManager::DisableStartup()
{
  if (@available(macOS 13.0, *))
  {
    NSError* err = nil;
    
    BOOL re = [[SMAppService mainAppService] unregisterAndReturnError: &err];
    if (re != NO || err != nil)
    {
      return false;
    }
    
    return true;
  }
  
  return false;
}

bool StartupManager::IsMacOS13OrHigher()
{
  if (@available(macOS 13.0, *))
  {
    return true;
  }
  
  return false;
}

