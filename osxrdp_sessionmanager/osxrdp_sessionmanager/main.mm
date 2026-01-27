//
//  main.m
//  osxrdp_sessionmanager
//
//  Created by byungho on 1/24/26.
//

#import <Foundation/Foundation.h>

#import "sessionmanager/sessionmanagerserver.h"

int main(int argc, const char * argv[]) {
    
    SessionManagerServer server;
    
    server.Start();
    
    pause();
    
    server.Stop();
        
    return EXIT_SUCCESS;
}
