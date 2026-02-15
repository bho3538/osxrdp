
#ifndef MultipleConnectionManager_h
#define MultipleConnectionManager_h

#include "../osxup.h"
#include <pthread.h>

class MultipleConnectionManager {
    
public:
    MultipleConnectionManager();
    ~MultipleConnectionManager();
    
    void AddConnection(struct mod* mod);
    void RemoveConnection();
    
private:
    struct mod* _CurrentConnected;
    
    pthread_mutex_t _lock;
};

#endif /* MultipleConnectionManager_h */
