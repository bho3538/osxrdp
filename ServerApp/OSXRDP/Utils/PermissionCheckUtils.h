
#ifndef PermissionCheckUtils_h
#define PermissionCheckUtils_h

class PermissionCheckUtils {
public:
    static bool HasAccPermission();
    
    static bool HasScreenRecordPermission();
    
    static void ShowAccPermissionRequestDialog();
    
    static void ShowScreenRecordPermissionRequestDialog();
    
    static void ResetAccPermission();
    
    static void ResetScreenRecordPermission();
    
    static bool HasAllPermissionToStartRemoteConnection();
};

#endif /* PermissionCheckUtils_h */
