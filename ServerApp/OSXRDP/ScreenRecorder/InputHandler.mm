#include "InputHandler.h"

#include "osxrdp/packet.h"
#import <AppKit/AppKit.h>
#include <stdlib.h>
#include <sys/time.h>
#include <Carbon/Carbon.h>
#include <string.h>
#include <limits.h>

#import "CJKHelper.h"

#define _IME_SWITCH_CODE kVK_RightOption

static const CGEventFlags kDeviceLeftControlFlag = 0x00000001;
static const CGEventFlags kDeviceLeftShiftFlag = 0x00000002;
static const CGEventFlags kDeviceRightShiftFlag = 0x00000004;
static const CGEventFlags kDeviceLeftCommandFlag = 0x00000008;
static const CGEventFlags kDeviceRightCommandFlag = 0x00000010;
static const CGEventFlags kDeviceLeftOptionFlag = 0x00000020;
static const CGEventFlags kDeviceRightOptionFlag = 0x00000040;
static const CGEventFlags kDeviceRightControlFlag = 0x00002000;

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
    _displayLayoutCnt(0),
    _scaleX(0.0f),
    _scaleY(0.0f),
    _lastMousePosX(0),
    _lastMousePosY(0),
    _lastMouseClickPosX(0),
    _lastMouseClickPosY(0),
    _eventRef(0),
    _keyboardModifierFlags(0),
    _mouseClickCnt(0),
    _mouseEventNumber(0),
    _leftMouseEventNumber(0),
    _rightMouseEventNumber(0),
    _wheelMouseEventNumber(0),
    _backMouseEventNumber(0),
    _forwardMouseEventNumber(0),
    _lastMouseButton(-1),
    _lastMouseClickTime(0),
    _lastMouseInputEventTime(0),
    _lastWheelEventTime(0),
    _wheelEventBurstCount(0),
    _fastWheelEventCount(0),
    _lastWheelDirection(0),
    _wheelSmoothedAmount(0.0f),
    _lastWheelIsTrackpad(false)
{
    memset(_displayLayouts, 0x00, sizeof(_displayLayouts));
    _eventRef = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
    
    _mouseKeyStatus.status = 0;
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
    
    printf("UpdateDisplayResolution origin: %d %d , record: %d %d , scale: %f %f\n", _originalDisplayWidth, _originalDisplayHeight, _recordDisplayWidth, _recordDisplayHeight, _scaleX, _scaleY);
}

void InputHandler::ResetDisplayLayout() {
    _displayLayoutCnt = 0;
    memset(_displayLayouts, 0x00, sizeof(_displayLayouts));
}

bool InputHandler::AddDisplayLayout(int clientLeft, int clientTop, int clientWidth, int clientHeight, int displayOriginX, int displayOriginY, int displayWidth, int displayHeight, int displayId) {
    if (_displayLayoutCnt >= 16) {
        return false;
    }

    if (clientWidth <= 0 || clientHeight <= 0 || displayWidth <= 0 || displayHeight <= 0 || displayId <= 0) {
        return false;
    }

    _displayLayouts[_displayLayoutCnt].clientLeft = clientLeft;
    _displayLayouts[_displayLayoutCnt].clientTop = clientTop;
    _displayLayouts[_displayLayoutCnt].clientWidth = clientWidth;
    _displayLayouts[_displayLayoutCnt].clientHeight = clientHeight;
    _displayLayouts[_displayLayoutCnt].displayId = displayId;
    _displayLayouts[_displayLayoutCnt].displayOriginX = displayOriginX;
    _displayLayouts[_displayLayoutCnt].displayOriginY = displayOriginY;
    _displayLayouts[_displayLayoutCnt].scaleX = (float)displayWidth / (float)clientWidth;
    _displayLayouts[_displayLayoutCnt].scaleY = (float)displayHeight / (float)clientHeight;
    _displayLayoutCnt++;

    printf("AddDisplayLayout client: %d %d %d %d, display: %d %d %d %d, displayId: %d\n", clientLeft, clientTop, clientWidth, clientHeight, displayOriginX, displayOriginY, displayWidth, displayHeight, displayId);

    return true;
}

void InputHandler::HandleMousseInputEvent(xstream_t* cmd) {
    if (cmd == NULL) return;
        
    int key = xstream_readInt32(cmd);
    int clientX = xstream_readInt32(cmd);
    int clientY = xstream_readInt32(cmd);
    long long currentTime = GetCurrentEventTime();
    
    // 최소화/복원 등으로 입력 간격이 크게 벌어지면 이전 클릭 상태를 버린다.
    if (_lastMouseInputEventTime != 0 && currentTime - _lastMouseInputEventTime > 1500) {
        RestorePreviousMouseKeydownEvent();
        
        _mouseClickCnt = 0;
        _lastMouseButton = -1;
        _lastMouseClickTime = 0;
    }
    _lastMouseInputEventTime = currentTime;
    
    MapClientPointToDisplayPoint(clientX, clientY, &clientX, &clientY);
    
    CGPoint point = CGPointMake(clientX, clientY);
    CGEventRef ev = NULL;
    int mouseEventNumber = 0;

    switch (key) {
        case XRDP_MOUSE_MOVE: {
            
            CGMouseButton btn = kCGMouseButtonLeft;
            CGEventType mouseMoveFlags = kCGEventMouseMoved;
            if (_mouseKeyStatus.downStatus.leftKeyDown) {
                mouseMoveFlags = kCGEventLeftMouseDragged;
                mouseEventNumber = _leftMouseEventNumber;
            }
            else if (_mouseKeyStatus.downStatus.rightKeyDown) {
                mouseMoveFlags = kCGEventRightMouseDragged;
                btn = kCGMouseButtonRight;
                mouseEventNumber = _rightMouseEventNumber;
            }
            
            ev = CGEventCreateMouseEvent(_eventRef, mouseMoveFlags, point, btn);
            
            // xcode minimap 과 같은 일부 컨트롤을 움직이려면 아래와 같은 값들을 설정해야 함.
            int dx = clientX - _lastMousePosX;
            int dy = clientY - _lastMousePosY;
            
            CGEventSetIntegerValueField(ev, kCGMouseEventDeltaX, dx);
            CGEventSetIntegerValueField(ev, kCGMouseEventDeltaY, dy);
            
            _lastMousePosX = clientX;
            _lastMousePosY = clientY;
            
            break;
        }
        case XRDP_MOUSE_LBTNDOWN: {
            ev = CGEventCreateMouseEvent(_eventRef, kCGEventLeftMouseDown, point, kCGMouseButtonLeft);
            _mouseEventNumber = (_mouseEventNumber == INT_MAX) ? 1 : _mouseEventNumber + 1;
            _leftMouseEventNumber = _mouseEventNumber;
            mouseEventNumber = _leftMouseEventNumber;
            
            HandleMouseDoubleClick(ev, true, clientX, clientY, kCGMouseButtonLeft);
            
            _mouseKeyStatus.downStatus.leftKeyDown = 1;
            
            break;
        }
        case XRDP_MOUSE_LBTNUP: {
            ev = CGEventCreateMouseEvent(_eventRef, kCGEventLeftMouseUp, point, kCGMouseButtonLeft);
            mouseEventNumber = _leftMouseEventNumber;
            
            HandleMouseDoubleClick(ev, false, clientX, clientY, kCGMouseButtonLeft);
            
            _mouseKeyStatus.downStatus.leftKeyDown = 0;
            
            break;
        }
        case XRDP_MOUSE_RBTNDOWN: {
            ev = CGEventCreateMouseEvent(_eventRef, kCGEventRightMouseDown, point, kCGMouseButtonRight);
            _mouseEventNumber = (_mouseEventNumber == INT_MAX) ? 1 : _mouseEventNumber + 1;
            _rightMouseEventNumber = _mouseEventNumber;
            mouseEventNumber = _rightMouseEventNumber;
            
            HandleMouseDoubleClick(ev, true, clientX, clientY, kCGMouseButtonRight);
            
            _mouseKeyStatus.downStatus.rightKeyDown = 1;

            break;
        }
        case XRDP_MOUSE_RBTNUP: {
            ev = CGEventCreateMouseEvent(_eventRef, kCGEventRightMouseUp, point, kCGMouseButtonRight);
            mouseEventNumber = _rightMouseEventNumber;
            
            HandleMouseDoubleClick(ev, false, clientX, clientY, kCGMouseButtonRight);
            
            _mouseKeyStatus.downStatus.rightKeyDown = 0;

            break;
        }
        case XRDP_MOUSE_MBTNDOWN: {
            ev = CGEventCreateMouseEvent(_eventRef, kCGEventOtherMouseDown, point, (CGMouseButton)2);
            _mouseEventNumber = (_mouseEventNumber == INT_MAX) ? 1 : _mouseEventNumber + 1;
            _wheelMouseEventNumber = _mouseEventNumber;
            mouseEventNumber = _wheelMouseEventNumber;
            
            _mouseKeyStatus.downStatus.wheelKeyDown = 1;
            
            break;
        }
        case XRDP_MOUSE_MBTNUP: {
            ev = CGEventCreateMouseEvent(_eventRef, kCGEventOtherMouseUp, point, (CGMouseButton)2);
            mouseEventNumber = _wheelMouseEventNumber;
            
            _mouseKeyStatus.downStatus.wheelKeyDown = 0;
            
            break;
        }
        case XRDP_MOUSE_WHEELUP : {
            int amount = GetMouseWheelMoveAmount(1);
            if (_lastWheelIsTrackpad) {
                PostTrackpadScrollEvent(amount);
                return;
            }
            PostScrollEvent(amount, false);
            return;
        }
        case XRDP_MOUSE_WHEELDOWN : {
            int amount = GetMouseWheelMoveAmount(-1) * -1;
            if (_lastWheelIsTrackpad) {
                PostTrackpadScrollEvent(amount);
                return;
            }
            PostScrollEvent(amount, false);
            return;
        }
        case XRDP_MOUSE_BBTNUP: {
            ev = CGEventCreateMouseEvent(_eventRef, kCGEventOtherMouseUp, point, (CGMouseButton)3);
            mouseEventNumber = _backMouseEventNumber;
            
            _mouseKeyStatus.downStatus.backKeyDown = 0;
            
            break;
        }
        case XRDP_MOUSE_BBTNDOWN: {
            ev = CGEventCreateMouseEvent(_eventRef, kCGEventOtherMouseDown, point, (CGMouseButton)3);
            _mouseEventNumber = (_mouseEventNumber == INT_MAX) ? 1 : _mouseEventNumber + 1;
            _backMouseEventNumber = _mouseEventNumber;
            mouseEventNumber = _backMouseEventNumber;
            
            _mouseKeyStatus.downStatus.backKeyDown = 1;
            
            break;
        }
        case XRDP_MOUSE_FBTNUP: {
            ev = CGEventCreateMouseEvent(_eventRef, kCGEventOtherMouseUp, point, (CGMouseButton)4);
            mouseEventNumber = _forwardMouseEventNumber;
            
            _mouseKeyStatus.downStatus.forwardKeyDown = 0;
            
            break;
        }
        case XRDP_MOUSE_FBTNDOWN: {
            ev = CGEventCreateMouseEvent(_eventRef, kCGEventOtherMouseDown, point, (CGMouseButton)4);
            _mouseEventNumber = (_mouseEventNumber == INT_MAX) ? 1 : _mouseEventNumber + 1;
            _forwardMouseEventNumber = _mouseEventNumber;
            mouseEventNumber = _forwardMouseEventNumber;
            
            _mouseKeyStatus.downStatus.forwardKeyDown = 1;

            break;
        }
        default:
            return;
    }
    
    CGEventSetIntegerValueField(ev, kCGMouseEventNumber, mouseEventNumber);
    CGEventPost(kCGSessionEventTap, ev);
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
    
    
    if (keyCode == _IME_SWITCH_CODE) {
        SwitchIME(inputType == XRDP_KEYBOARD_DOWN);
        return;
    }
        
    bool keyDown = false;
    switch (inputType) {
        case XRDP_KEYBOARD_DOWN:
            keyDown = true;
            break;
        case XRDP_KEYBOARD_UP:
            keyDown = false;
            break;
        default:
            return;
    }
    
    CGEventRef ev = CGEventCreateKeyboardEvent(_eventRef, keyCode, keyDown);
    ModifierStateChange modifierState = UpdateKeyboardModifierState(keyCode, keyDown);
    if (modifierState == ModifierStateChanged) {
        CGEventSetType(ev, kCGEventFlagsChanged);
    }
    else if (modifierState == ModifierStateUnchanged) {
        CFRelease(ev);
        return;
    }

    // 미션 컨트롤
    CGEventFlags eventFlags = _keyboardModifierFlags;
    if ((eventFlags & kCGEventFlagMaskControl) != 0 &&
        (keyCode == kVK_UpArrow || keyCode == kVK_DownArrow ||
         keyCode == kVK_LeftArrow || keyCode == kVK_RightArrow)) {
        eventFlags |= kCGEventFlagMaskSecondaryFn;
    }
    CGEventSetFlags(ev, eventFlags);
    
    CGEventPost(kCGSessionEventTap, ev);
    CFRelease(ev);
}

void InputHandler::HandleMouseDoubleClick(CGEventRef ev, bool mouseDown, int mouseX, int mouseY, int mouseButton) {
    if (mouseDown) {
        long long currentTime = GetCurrentEventTime();
        if (mouseButton == _lastMouseButton && currentTime - _lastMouseClickTime < 400) {
            int gap = abs(mouseX - _lastMouseClickPosX) + abs(mouseY - _lastMouseClickPosY);
            if (gap < 5) {
                _mouseClickCnt++;
            }
            else {
                _mouseClickCnt = 1;
            }
        }
        else {
            _mouseClickCnt = 1;
        }
        
        _lastMouseClickPosX = mouseX;
        _lastMouseClickPosY = mouseY;
        _lastMouseButton = mouseButton;
        _lastMouseClickTime = currentTime;
    }
    
    CGEventSetIntegerValueField(ev, kCGMouseEventClickState, _mouseClickCnt);
}

bool InputHandler::MapClientPointToDisplayPoint(int clientX, int clientY, int* outX, int* outY) {
    if (outX == NULL || outY == NULL) {
        return false;
    }

    for (int i = 0; i < _displayLayoutCnt; i++) {
        struct DISPLAY_LAYOUT* layout = &_displayLayouts[i];
        if (layout->clientWidth <= 0 || layout->clientHeight <= 0 || layout->displayId <= 0) {
            continue;
        }

        if (clientX < layout->clientLeft || clientY < layout->clientTop ||
            clientX >= layout->clientLeft + layout->clientWidth ||
            clientY >= layout->clientTop + layout->clientHeight) {
            continue;
        }

        int localX = clientX - layout->clientLeft;
        int localY = clientY - layout->clientTop;

        *outX = layout->displayOriginX + (int)((float)localX * layout->scaleX);
        *outY = layout->displayOriginY + (int)((float)localY * layout->scaleY);

        return true;
    }

    *outX = CalcPos(clientX, _scaleX);
    *outY = CalcPos(clientY, _scaleY);
    return false;
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

int InputHandler::GetMouseWheelMoveAmount(int direction) {
    const int kIdleGapMs = 180;
    const int kFastWheelGapMs = 18;
    const int kTrackpadGapMs = 45;
    const int kMouseConfirmGapMs = 80;
    const int kTrackpadMinAmount = 6;
    const int kTrackpadMaxAmount = 32;
    const int kMouseMinAmount = 1;
    const int kMouseMaxAmount = 7;

    if (direction > 0) {
        direction = 1;
    }
    else if (direction < 0) {
        direction = -1;
    }
    else {
        direction = 0;
    }
    
    long long currentTime = GetCurrentEventTime();
    long long gap = 0;
    bool newGesture = false;
    
    if (_lastWheelEventTime == 0) {
        newGesture = true;
    }
    else {
        gap = currentTime - _lastWheelEventTime;
        if (gap > kIdleGapMs) {
            newGesture = true;
        }
    }
    
    if (direction != 0 && _lastWheelDirection != 0 && direction != _lastWheelDirection) {
        newGesture = true;
    }
    
    if (newGesture) {
        _wheelEventBurstCount = 0;
        _fastWheelEventCount = 0;
    }
    else {
        _wheelEventBurstCount++;
    }
    
    // 아주 짧은 간격이 연속으로 들어올 때만 트랙패드로 본다.
    if (!newGesture && gap <= kFastWheelGapMs) {
        _fastWheelEventCount++;
    }
    else if (newGesture || gap >= kMouseConfirmGapMs) {
        _fastWheelEventCount = 0;
    }

    if (_lastWheelEventTime != 0) {
        if (_lastWheelIsTrackpad) {
            if (gap >= kMouseConfirmGapMs) {
                _lastWheelIsTrackpad = false;
            }
        }
        else if (!newGesture && gap <= kTrackpadGapMs && _fastWheelEventCount >= 2) {
            _lastWheelIsTrackpad = true;
        }
        else if (gap >= kMouseConfirmGapMs) {
            _lastWheelIsTrackpad = false;
        }
    }
    
    int target = 0;
    if (_lastWheelIsTrackpad) {
        if (gap <= 14) {
            target = 32;
        }
        else if (gap <= 24) {
            target = 24;
        }
        else if (gap <= kTrackpadGapMs) {
            target = 18;
        }
        else {
            target = 14;
        }
        
        if (newGesture) {
            target = 12;
        }
        
        if (_wheelEventBurstCount > 18 && target > 16) {
            target -= 4;
        }
    }
    else {
        if (newGesture) {
            target = 2;
        }
        else if (gap <= 40) {
            target = 12;
        }
        else if (gap <= 60) {
            target = 8;
        }
        else if (gap <= 90) {
            target = 6;
        }
        else if (gap <= 130) {
            target = 5;
        }
        else {
            target = 3;
        }
    }
    
    if (newGesture) {
        _wheelSmoothedAmount = (float)target;
    }
    else {
        float alpha = _lastWheelIsTrackpad ? 0.35f : 0.65f;
        _wheelSmoothedAmount = (_wheelSmoothedAmount * (1.0f - alpha)) + (((float)target) * alpha);
    }
    
    int amount = (int)(_wheelSmoothedAmount + 0.5f);
    if (_lastWheelIsTrackpad) {
        if (amount < kTrackpadMinAmount) {
            amount = kTrackpadMinAmount;
        }
        else if (amount > kTrackpadMaxAmount) {
            amount = kTrackpadMaxAmount;
        }
    }
    else {
        if (amount < kMouseMinAmount) {
            amount = kMouseMinAmount;
        }
        else if (amount > kMouseMaxAmount) {
            amount = kMouseMaxAmount;
        }
    }
    
    _lastWheelEventTime = currentTime;
    _lastWheelDirection = direction;
    return amount;
}

void InputHandler::PostScrollEvent(int amount, bool continuous) {
    CGScrollEventUnit unit = continuous ? kCGScrollEventUnitPixel : kCGScrollEventUnitLine;
    CGEventRef ev = CGEventCreateScrollWheelEvent(NULL, unit, 1, amount, 0);
    if (ev == NULL) {
        return;
    }

    // 트랙패드 스타일의 스크롤 설정 (연속되는 이벤트의 경우)
    if (continuous) {
        CGEventSetIntegerValueField(ev, kCGScrollWheelEventIsContinuous, 1);
    }

    CGEventPost(kCGSessionEventTap, ev);
    CFRelease(ev);
}

void InputHandler::PostTrackpadScrollEvent(int amount) {
    int absAmount = abs(amount);
    if (absAmount <= 0) {
        return;
    }

    int steps = 1;
    if (absAmount > 14) {
        steps = 3;
    }
    else if (absAmount > 8) {
        steps = 2;
    }

    int base = absAmount / steps;
    int remain = absAmount % steps;
    int sign = (amount < 0) ? -1 : 1;

    for (int i = 0; i < steps; i++) {
        int part = base + ((i < remain) ? 1 : 0);
        if (part <= 0) {
            continue;
        }
        PostScrollEvent(part * sign, true);
    }
}

CGKeyCode InputHandler::MapExtendedKey(int scancode) {
    switch (scancode) {
        case 0x1C: return kVK_ANSI_KeypadEnter;
        case 0x1D: return kVK_RightControl;
        case 0x35: return kVK_ANSI_KeypadDivide;
        case 0x37: return kVK_F13; // PrintScreen
        case 0x38: return kVK_RightOption; // R Alt
        case 0x72: return kVK_RightOption;
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

InputHandler::ModifierStateChange InputHandler::UpdateKeyboardModifierState(CGKeyCode key, bool isDown) {
    CGEventFlags oldFlags = _keyboardModifierFlags;
    CGEventFlags deviceFlag = 0;
    CGEventFlags groupFlag = 0;
    CGEventFlags groupDeviceFlags = 0;
    switch (key) {
        case 56: // Shift (Left)
            deviceFlag = kDeviceLeftShiftFlag;
            groupFlag = kCGEventFlagMaskShift;
            groupDeviceFlags = kDeviceLeftShiftFlag | kDeviceRightShiftFlag;
            break;
        case 60: // Shift (Right)
            deviceFlag = kDeviceRightShiftFlag;
            groupFlag = kCGEventFlagMaskShift;
            groupDeviceFlags = kDeviceLeftShiftFlag | kDeviceRightShiftFlag;
            break;
        case 59: // Control (Left)
            deviceFlag = kDeviceLeftControlFlag;
            groupFlag = kCGEventFlagMaskControl;
            groupDeviceFlags = kDeviceLeftControlFlag | kDeviceRightControlFlag;
            break;
        case 62: // Control (Right)
            deviceFlag = kDeviceRightControlFlag;
            groupFlag = kCGEventFlagMaskControl;
            groupDeviceFlags = kDeviceLeftControlFlag | kDeviceRightControlFlag;
            break;
        case 58: // Option (Left)
            deviceFlag = kDeviceLeftOptionFlag;
            groupFlag = kCGEventFlagMaskAlternate;
            groupDeviceFlags = kDeviceLeftOptionFlag | kDeviceRightOptionFlag;
            break;
        case 61: // Option (Right)
            deviceFlag = kDeviceRightOptionFlag;
            groupFlag = kCGEventFlagMaskAlternate; // Option key
            groupDeviceFlags = kDeviceLeftOptionFlag | kDeviceRightOptionFlag;
            break;
        //case 29: // Win (Ctrl)
        case 55: // Command (Left)
            deviceFlag = kDeviceLeftCommandFlag;
            groupFlag = kCGEventFlagMaskCommand;
            groupDeviceFlags = kDeviceLeftCommandFlag | kDeviceRightCommandFlag;
            break;
        case 54: // Command (Right)
            deviceFlag = kDeviceRightCommandFlag;
            groupFlag = kCGEventFlagMaskCommand;
            groupDeviceFlags = kDeviceLeftCommandFlag | kDeviceRightCommandFlag;
            break;
        case 57: // CapsLock
            if (isDown) _keyboardModifierFlags ^= kCGEventFlagMaskAlphaShift;
            return oldFlags != _keyboardModifierFlags ? ModifierStateChanged : ModifierStateUnchanged;
        default:
            return ModifierStateNotModifier; // normal key
    }

    if (isDown) {
        _keyboardModifierFlags |= deviceFlag | groupFlag;
    }
    else {
        _keyboardModifierFlags &= ~deviceFlag;
        if ((_keyboardModifierFlags & groupDeviceFlags) == 0) {
            _keyboardModifierFlags &= ~groupFlag;
        }
    }
        
    return oldFlags != _keyboardModifierFlags ? ModifierStateChanged : ModifierStateUnchanged;
}

void InputHandler::SwitchIME(bool keyDown) {
    if (!keyDown) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        OSStatus status = [CJKHelper selectNextInputSourceWithWorkaround];

        if (status != noErr) {
            NSLog(@"[InputHandler] Failed to switch input source. Error: %d", (int)status);
        }
    });
}

void InputHandler::RestorePreviousMouseKeydownEvent() {
    if (_mouseKeyStatus.status == 0) {
        return;
    }

    CGPoint point = CGPointMake(_lastMousePosX, _lastMousePosY);
    CGEventRef ev = NULL;

    if (_mouseKeyStatus.downStatus.leftKeyDown) {
        ev = CGEventCreateMouseEvent(_eventRef, kCGEventLeftMouseUp, point, kCGMouseButtonLeft);
        if (ev != NULL) {
            CGEventPost(kCGSessionEventTap, ev);
            CFRelease(ev);
        }
    }

    if (_mouseKeyStatus.downStatus.rightKeyDown) {
        ev = CGEventCreateMouseEvent(_eventRef, kCGEventRightMouseUp, point, kCGMouseButtonRight);
        if (ev != NULL) {
            CGEventPost(kCGSessionEventTap, ev);
            CFRelease(ev);
        }
    }

    if (_mouseKeyStatus.downStatus.wheelKeyDown) {
        ev = CGEventCreateMouseEvent(_eventRef, kCGEventOtherMouseUp, point, (CGMouseButton)2);
        if (ev != NULL) {
            CGEventPost(kCGSessionEventTap, ev);
            CFRelease(ev);
        }
    }

    if (_mouseKeyStatus.downStatus.backKeyDown) {
        ev = CGEventCreateMouseEvent(_eventRef, kCGEventOtherMouseUp, point, (CGMouseButton)3);
        if (ev != NULL) {
            CGEventPost(kCGSessionEventTap, ev);
            CFRelease(ev);
        }
    }

    if (_mouseKeyStatus.downStatus.forwardKeyDown) {
        ev = CGEventCreateMouseEvent(_eventRef, kCGEventOtherMouseUp, point, (CGMouseButton)4);
        if (ev != NULL) {
            CGEventPost(kCGSessionEventTap, ev);
            CFRelease(ev);
        }
    }

    _mouseKeyStatus.status = 0;
}
