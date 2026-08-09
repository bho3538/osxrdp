#ifndef InputHandler_hpp
#define InputHandler_hpp

#include "xstream.h"
#include <ApplicationServices/ApplicationServices.h>

class InputHandler {
public:
    InputHandler();
    ~InputHandler();
    
    void UpdateDisplayRes(int originalDisplayWidth, int originalDisplayHeight, int recordDisplayWidth, int recordDisplayHeight);
    void ResetDisplayLayout();
    bool AddDisplayLayout(int clientLeft, int clientTop, int clientWidth, int clientHeight, int displayOriginX, int displayOriginY, int displayWidth, int displayHeight, int displayId);
    
    void HandleMousseInputEvent(xstream_t* cmd);
    void HandleKeyboardInputEvent(xstream_t* cmd);
    
private:
    struct DISPLAY_LAYOUT {
        int clientLeft;
        int clientTop;
        int clientWidth;
        int clientHeight;
        int displayId;
        int displayOriginX;
        int displayOriginY;
        float scaleX;
        float scaleY;
    };

    int _originalDisplayWidth;
    int _originalDisplayHeight;
    int _recordDisplayWidth;
    int _recordDisplayHeight;

    struct DISPLAY_LAYOUT _displayLayouts[16];
    int _displayLayoutCnt;
    
    int _lastMousePosX;
    int _lastMousePosY;
    int _lastMouseClickPosX;
    int _lastMouseClickPosY;
    
    float _scaleX;
    float _scaleY;
    
    union MOUSE_DOWN_STATUS {
        struct STATUS {
            char leftKeyDown;
            char rightKeyDown;
            char wheelKeyDown;
            char backKeyDown;
            char forwardKeyDown;
            char dummy1;
            char dummy2;
            char dummy3;
        } downStatus;
        unsigned long status;
    } _mouseKeyStatus;
    
    int _mouseClickCnt;
    int _mouseEventNumber;
    int _leftMouseEventNumber;
    int _rightMouseEventNumber;
    int _wheelMouseEventNumber;
    int _backMouseEventNumber;
    int _forwardMouseEventNumber;
    int _lastMouseButton;
    long long _lastMouseClickTime;
    long long _lastMouseInputEventTime;
    long long _lastWheelEventTime;
    int _wheelEventBurstCount;
    int _fastWheelEventCount;
    int _lastWheelDirection;
    float _wheelSmoothedAmount;
    bool _lastWheelIsTrackpad;
    
    CGEventFlags _keyboardModifierFlags;
    
    CGEventSourceRef _eventRef;
    
    void HandleKeyboardSyncEvent();
    void HandleMouseDoubleClick(CGEventRef ev, bool mouseDown, int mouseX, int mouseY, int mouseButton);
    bool MapClientPointToDisplayPoint(int clientX, int clientY, int* outX, int* outY);
    int GetMouseWheelMoveAmount(int direction);
    void PostScrollEvent(int amount, bool continuous);
    void PostTrackpadScrollEvent(int amount);
    
    void RestorePreviousMouseKeydownEvent();
    
    static int CalcPos(int clientPos, float scale);
    
    static long long GetCurrentEventTime();
    
    enum ModifierStateChange {
        ModifierStateNotModifier,
        ModifierStateUnchanged,
        ModifierStateChanged
    };

    CGKeyCode MapExtendedKey(int scancode);
    ModifierStateChange UpdateKeyboardModifierState(CGKeyCode key, bool isDown);
    
    void SwitchIME(bool keyDown);
};

#endif /* InputHandler_hpp */
