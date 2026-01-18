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
    
    float _scaleX;
    float _scaleY;
    
    int _inMouseDown;
    int _mouseClickCnt;
    long long _lastMouseClickTime;
    long long _lastWheelMoveLargeTime;
    
    CGEventFlags _keyboardModifierFlags;
    
    CGEventSourceRef _eventRef;
    
    void HandleMouseDoubleClick(CGEventRef ev, bool mouseDown, int mouseX, int mouseY);
    int GetMouseWheelMoveAmount();
    
    static int CalcPos(int clientPos, float scale);
    
    static long long GetCurrentEventTime();
    
    CGKeyCode MapExtendedKey(int scancode);
    bool UpdateKeyboardModifierState(CGKeyCode key, bool isDown);
};

#endif /* InputHandler_hpp */

