//
//  HIDOffload.h
//  MinisApp
//
//  ly patch — native offload handler for `apple-hid`.
//  System-wide touch injection, keyboard input and full-screen capture.
//

#ifndef HIDOffload_h
#define HIDOffload_h

/// Register the apple-hid native handler.
void hid_offload_register(void);

#endif /* HIDOffload_h */
