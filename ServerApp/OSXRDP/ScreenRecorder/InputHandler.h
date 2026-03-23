#ifndef InputHandler_hpp
#define InputHandler_hpp

#include "xstream.h"
#include <ApplicationServices/ApplicationServices.h>

class InputHandler {
public:
    InputHandler();
    ~InputHandler();
    
    void UpdateDisplayRes(int originalDisplayWidth, int originalDisplayHeight, int recordDisplayWidth, int recordDisplayHeight);
    
    void HandleMousseInputEvent(xstream_t* cmd);
    void HandleKeyboardInputEvent(xstream_t* cmd);
    
private:
    int _originalDisplayWidth;
    int _originalDisplayHeight;
    int _recordDisplayWidth;
    int _recordDisplayHeight;
    
    int _lastMousePosX;
    int _lastMousePosY;
    int _lastMouseClickPosX;
    int _lastMouseClickPosY;
    
    float _scaleX;
    float _scaleY;
    
    int _inMouseDown;
    int _mouseClickCnt;
    int _lastMouseButton;
    long long _lastMouseClickTime;
    long long _lastMouseInputEventTime;
    long long _lastWheelEventTime;
    int _wheelEventBurstCount;
    int _lastWheelDirection;
    float _wheelSmoothedAmount;
    bool _lastWheelIsTrackpad;
    
    CGEventFlags _keyboardModifierFlags;
    
    CGEventSourceRef _eventRef;
    
    void HandleMouseDoubleClick(CGEventRef ev, bool mouseDown, int mouseX, int mouseY, int mouseButton);
    int GetMouseWheelMoveAmount(int direction);
    void PostScrollEvent(int amount, bool continuous);
    void PostTrackpadScrollEvent(int amount);
    void ResetMouseInputState(CGPoint point);
    void RecreateEventSource();
    void ReleaseModifierKeys();
    
    static int CalcPos(int clientPos, float scale);
    
    static long long GetCurrentEventTime();
    
    CGKeyCode MapExtendedKey(int scancode);
    bool UpdateKeyboardModifierState(CGKeyCode key, bool isDown);
    
    void SwitchIME();
};

#endif /* InputHandler_hpp */
