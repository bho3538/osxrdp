#include "InputHandler.h"

#include "osxrdp/packet.h"
#include <stdlib.h>
#include <sys/time.h>
#include <Carbon/Carbon.h>

static const CGKeyCode keymap[] = {
    /* 0x00 */ kVK_ANSI_A,                      // Placeholder (No key)
    /* 0x01 */ kVK_Escape,                      // ESC
    /* 0x02 */ kVK_ANSI_1,
    /* 0x03 */ kVK_ANSI_2,
    /* 0x04 */ kVK_ANSI_3,
    /* 0x05 */ kVK_ANSI_4,
    /* 0x06 */ kVK_ANSI_5,
    /* 0x07 */ kVK_ANSI_6,
    /* 0x08 */ kVK_ANSI_7,
    /* 0x09 */ kVK_ANSI_8,
    /* 0x0a */ kVK_ANSI_9,
    /* 0x0b */ kVK_ANSI_0,
    /* 0x0c */ kVK_ANSI_Minus,
    /* 0x0d */ kVK_ANSI_Equal,
    /* 0x0e */ kVK_Delete,                      // Backspace
    /* 0x0f */ kVK_Tab,
    /* 0x10 */ kVK_ANSI_Q,
    /* 0x11 */ kVK_ANSI_W,
    /* 0x12 */ kVK_ANSI_E,
    /* 0x13 */ kVK_ANSI_R,
    /* 0x14 */ kVK_ANSI_T,
    /* 0x15 */ kVK_ANSI_Y,
    /* 0x16 */ kVK_ANSI_U,
    /* 0x17 */ kVK_ANSI_I,
    /* 0x18 */ kVK_ANSI_O,
    /* 0x19 */ kVK_ANSI_P,
    /* 0x1a */ kVK_ANSI_LeftBracket,
    /* 0x1b */ kVK_ANSI_RightBracket,
    /* 0x1c */ kVK_Return,                      // Enter
    /* 0x1d */ kVK_Control,                     // L Ctrl
    /* 0x1e */ kVK_ANSI_A,
    /* 0x1f */ kVK_ANSI_S,
    /* 0x20 */ kVK_ANSI_D,
    /* 0x21 */ kVK_ANSI_F,
    /* 0x22 */ kVK_ANSI_G,
    /* 0x23 */ kVK_ANSI_H,
    /* 0x24 */ kVK_ANSI_J,
    /* 0x25 */ kVK_ANSI_K,
    /* 0x26 */ kVK_ANSI_L,
    /* 0x27 */ kVK_ANSI_Semicolon,
    /* 0x28 */ kVK_ANSI_Quote,
    /* 0x29 */ kVK_ANSI_Grave,                  // ` (Backtick)
    /* 0x2a */ kVK_Shift,                       // L Shift
    /* 0x2b */ kVK_ANSI_Backslash,
    /* 0x2c */ kVK_ANSI_Z,
    /* 0x2d */ kVK_ANSI_X,
    /* 0x2e */ kVK_ANSI_C,
    /* 0x2f */ kVK_ANSI_V,
    /* 0x30 */ kVK_ANSI_B,
    /* 0x31 */ kVK_ANSI_N,
    /* 0x32 */ kVK_ANSI_M,
    /* 0x33 */ kVK_ANSI_Comma,
    /* 0x34 */ kVK_ANSI_Period,
    /* 0x35 */ kVK_ANSI_Slash,
    /* 0x36 */ kVK_RightShift,
    /* 0x37 */ kVK_ANSI_KeypadMultiply,
    /* 0x38 */ kVK_Option,                      // L Alt (Mac Option)
    /* 0x39 */ kVK_Space,
    /* 0x3a */ kVK_CapsLock,
    /* 0x3b */ kVK_F1,
    /* 0x3c */ kVK_F2,
    /* 0x3d */ kVK_F3,
    /* 0x3e */ kVK_F4,
    /* 0x3f */ kVK_F5,
    /* 0x40 */ kVK_F6,
    /* 0x41 */ kVK_F7,
    /* 0x42 */ kVK_F8,
    /* 0x43 */ kVK_F9,
    /* 0x44 */ kVK_F10,
    /* 0x45 */ kVK_ANSI_KeypadClear,            // NumLock
    /* 0x46 */ kVK_F14,                         // Scroll Lock
    /* 0x47 */ kVK_ANSI_Keypad7,
    /* 0x48 */ kVK_ANSI_Keypad8,
    /* 0x49 */ kVK_ANSI_Keypad9,
    /* 0x4a */ kVK_ANSI_KeypadMinus,
    /* 0x4b */ kVK_ANSI_Keypad4,
    /* 0x4c */ kVK_ANSI_Keypad5,
    /* 0x4d */ kVK_ANSI_Keypad6,
    /* 0x4e */ kVK_ANSI_KeypadPlus,
    /* 0x4f */ kVK_ANSI_Keypad1,
    /* 0x50 */ kVK_ANSI_Keypad2,
    /* 0x51 */ kVK_ANSI_Keypad3,
    /* 0x52 */ kVK_ANSI_Keypad0,
    /* 0x53 */ kVK_ANSI_KeypadDecimal,
    /* 0x54 */ kVK_F13,                         // SysReq
    /* 0x55 */ 0xFF,                            // (Not mapped)
    /* 0x56 */ 0xFF,                            // (Not mapped)
    /* 0x57 */ kVK_F11,
    /* 0x58 */ kVK_F12,
    /* 0x59 */ kVK_ANSI_KeypadEquals, // Keypad =
};

InputHandler::InputHandler() :
    _originalDisplayWidth(0),
    _originalDisplayHeight(0),
    _recordDisplayWidth(0),
    _recordDisplayHeight(0),
    _scaleX(0.0f),
    _scaleY(0.0f),
    _inMouseDown(0),
    _mousePosX(0),
    _mousePosY(0),
    _eventRef(0),
    _keyboardModifierFlags(0),
    _mouseClickCnt(0),
    _lastMouseClickTime(0)
{
    _eventRef = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
}

InputHandler::~InputHandler() {
    if (_eventRef != 0) {
        CFRelease(_eventRef);
        _eventRef = 0;
    }
}

void InputHandler::UpdateDisplayRes(int originalDisplayWidth, int originalDisplayHeight, int recordDisplayWidth, int recordDisplayHeight) {
    _originalDisplayWidth = originalDisplayWidth;
    _originalDisplayHeight = originalDisplayHeight;
    _recordDisplayWidth = recordDisplayWidth;
    _recordDisplayHeight = recordDisplayHeight;
    
    _scaleX = (float)_originalDisplayWidth / _recordDisplayWidth;
    _scaleY = (float)_originalDisplayHeight / _recordDisplayHeight;
}

void InputHandler::HandleMousseInputEvent(xstream_t* cmd) {
    if (cmd == NULL) return;
        
    int key = xstream_readInt32(cmd);
    int clientX = xstream_readInt32(cmd);
    int clientY = xstream_readInt32(cmd);
    
    clientX = CalcPos(clientX, _scaleX);
    clientY = CalcPos(clientY, _scaleY);
    
    CGPoint point = CGPointMake(clientX, clientY);
    CGEventRef ev;

    switch (key) {
        case XRDP_MOUSE_MOVE: {
            ev = CGEventCreateMouseEvent(_eventRef, _inMouseDown == 1 ? kCGEventLeftMouseDragged : kCGEventMouseMoved, point, kCGMouseButtonLeft);
            break;
        }
        case XRDP_MOUSE_LBTNDOWN: {
            ev = CGEventCreateMouseEvent(_eventRef, kCGEventLeftMouseDown, point, kCGMouseButtonLeft);
            
            HandleMouseDoubleClick(ev, true);
            
            _inMouseDown = 1;
            break;
        }
        case XRDP_MOUSE_LBTNUP: {
            ev = CGEventCreateMouseEvent(_eventRef, kCGEventLeftMouseUp, point, kCGMouseButtonLeft);
            
            HandleMouseDoubleClick(ev, false);
            
            _inMouseDown = 0;
            break;
        }
        case XRDP_MOUSE_RBTNDOWN: {
            ev = CGEventCreateMouseEvent(_eventRef, kCGEventRightMouseDown, point, kCGMouseButtonRight);
            
            HandleMouseDoubleClick(ev, true);
            
            _inMouseDown = 1;
            break;
        }
        case XRDP_MOUSE_RBTNUP: {
            ev = CGEventCreateMouseEvent(_eventRef, kCGEventRightMouseUp, point, kCGMouseButtonRight);
            
            HandleMouseDoubleClick(ev, false);
            
            _inMouseDown = 0;
            break;
        }
        case XRDP_MOUSE_WHEELUP : {
            ev = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 1, 35, 0);
            break;
        }
        case XRDP_MOUSE_WHEELDOWN : {
            ev = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 1, -35, 0);
            break;
        }
        case XRDP_MOUSE_BBTNUP: {
            ev = CGEventCreateMouseEvent(_eventRef, kCGEventOtherMouseUp, point, (CGMouseButton)3);
            break;
        }
        case XRDP_MOUSE_BBTNDOWN: {
            ev = CGEventCreateMouseEvent(_eventRef, kCGEventOtherMouseDown, point, (CGMouseButton)3);
            break;
        }
        case XRDP_MOUSE_FBTNUP: {
            ev = CGEventCreateMouseEvent(_eventRef, kCGEventOtherMouseUp, point, (CGMouseButton)4);
            break;
        }
        case XRDP_MOUSE_FBTNDOWN: {
            ev = CGEventCreateMouseEvent(_eventRef, kCGEventOtherMouseDown, point, (CGMouseButton)4);
            break;
        }
        default:
            return;
    }
    
    CGEventPost(kCGHIDEventTap, ev);
    CFRelease(ev);
}

void InputHandler::HandleKeyboardInputEvent(xstream_t* cmd) {
    if (cmd == NULL) return;
    
    int inputType = xstream_readInt32(cmd);
    int keyCode = xstream_readInt32(cmd);
    int flags = xstream_readInt32(cmd);
    
    if (flags & 0x100) {
        // convert xrdp extended key code to macOS keycode
        keyCode = MapExtendedKey(keyCode & 0x7F);
    }
    else {
        // invalid keycode
        if (keyCode > 89) {
            return;
        }
        
        // convert xrdp key code to macOS keycode
        keyCode = keymap[keyCode];
    }
        
    CGEventRef ev;
    switch (inputType) {
        case XRDP_KEYBOARD_DOWN: {
            ev = CGEventCreateKeyboardEvent(_eventRef, keyCode, true);
            UpdateKeyboardModifierState(keyCode, true);
            break;
        }
        case XRDP_KEYBOARD_UP: {
            ev = CGEventCreateKeyboardEvent(_eventRef, keyCode, false);
            UpdateKeyboardModifierState(keyCode, false);

            break;
        }
        default:
            return;
    }
    
    CGEventSetFlags(ev, _keyboardModifierFlags);
    
    CGEventPost(kCGHIDEventTap, ev);
    CFRelease(ev);
}

void InputHandler::HandleMouseDoubleClick(CGEventRef ev, bool mouseDown) {
    if (mouseDown) {
        long long currentTime = GetCurrentEventTime();
        if (currentTime - _lastMouseClickTime < 500) {
            _mouseClickCnt++;
        }
        else {
            _mouseClickCnt = 1;
        }
        
        _lastMouseClickTime = currentTime;
    }
    
    CGEventSetIntegerValueField(ev, kCGMouseEventClickState, _mouseClickCnt);
}

int InputHandler::CalcPos(int clientPos, float scale) {
    if (scale == 1.0f) return clientPos;
    
    float calc = clientPos * scale;
    
    if (calc < 0) return 0;
    
    return (int)calc;
}

long long InputHandler::GetCurrentEventTime() {
    struct timeval te;
    gettimeofday(&te, NULL);
    return te.tv_sec * 1000LL + te.tv_usec / 1000;
}

CGKeyCode InputHandler::MapExtendedKey(int scancode) {
    switch (scancode) {
        case 0x1C: return kVK_ANSI_KeypadEnter;
        case 0x1D: return kVK_RightControl;
        case 0x35: return kVK_ANSI_KeypadDivide;
        case 0x37: return kVK_F13; // PrintScreen
        case 0x38: return kVK_RightOption; // R Alt
        case 0x47: return kVK_Home;
        case 0x48: return kVK_UpArrow;
        case 0x49: return kVK_PageUp;
        case 0x4B: return kVK_LeftArrow;
        case 0x4D: return kVK_RightArrow;
        case 0x4F: return kVK_End;
        case 0x50: return kVK_DownArrow;
        case 0x51: return kVK_PageDown;
        case 0x52: return kVK_ForwardDelete; // Insert
        case 0x53: return kVK_ForwardDelete; // Delete
        case 0x5B: return kVK_Command; // Left Windows -> Command
        case 0x5C: return kVK_RightCommand; // Right Windows -> Command
        case 0x5D: return kVK_F13; // App key -> (Menu)
        default: return 0xFF;
    }
}

bool InputHandler::UpdateKeyboardModifierState(CGKeyCode key, bool isDown) {
    CGEventFlags flag = 0;
    switch (key) {
        case 56: // Shift (Left)
        case 60: // Shift (Right)
            flag = kCGEventFlagMaskShift;
            break;
        case 59: // Control (Left)
        case 62: // Control (Right)
            flag = kCGEventFlagMaskControl;
            break;
        case 58: // Option (Left)
        case 61: // Option (Right)
            flag = kCGEventFlagMaskAlternate; // Option key
            break;
        //case 29: // Win (Ctrl)
        case 55: // Command (Left)
        case 54: // Command (Right)
            flag = kCGEventFlagMaskCommand;
            break;
        case 57: // CapsLock
            if (isDown) _keyboardModifierFlags ^= kCGEventFlagMaskAlphaShift;
            return true;
        default:
            return false; // normal key
    }

    if (isDown) {
        _keyboardModifierFlags |= flag;
    }
    else {
        _keyboardModifierFlags &= ~flag;
    }
        
    return true;
}
