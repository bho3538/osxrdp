//
//  main.m
//  osxrdp_sessionmanager
//
//  Created by byungho on 1/24/26.
//

#include "pch.h"
#include "utils.h"
#include "duprun.h"

#import "sessionmanager/sessionmanagerserver.h"

#define _LOG_CONFIG_PATH "/etc/osxrdp/log_sessionmanager.conf"

int main(int argc, const char * argv[]) {
    
    // initialize log
    int re = dzlog_init(_LOG_CONFIG_PATH, "osxrdp_sessionmanager");
    if (re != 0) {
        NSLog(@"[osxrdp_sessionmanager] could not initialize log. %s", _LOG_CONFIG_PATH);
        
        return 1;
    }
    
    // check is root process
    if (is_root_process() == 0) {
        NSLog(@"[osxrdp_sessionmanager] osxrdp sessionmanager must run as root.");
        dzlog_error("[osxrdp_sessionmanager] osxrdp sessionmanager must run as root.");
        
        return 1;
    }
    
    // 중복 실행 확인
    duprun* dup = duprun_initialize("com.byungho.osxrdp.sessionmanager");
    if (dup == NULL) {
        NSLog(@"[osxrdp_sessionmanager] program already running.");
        dzlog_error("[osxrdp_sessionmanager] program already running.");
        
        return 1;
    }
    
    dzlog_info("[osxrdp_sessionmanager] --- osxrdp sessionmanager started! ---");
    dzlog_info("[osxrdp_sessionmanager] created by byungho kim - https://github.com/bho3538/osxrdp");
    
    SessionManagerServer server;
    
    server.Start();
    
    pause();
    
    server.Stop();
    
    duprun_release(dup);
    dup = NULL;
    
    dzlog_info("[osxrdp_sessionmanager] --- osxrdp sessionmanager ended ---");
    
    return EXIT_SUCCESS;
}
