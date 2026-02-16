
#include "MultipleConnectionManager.h"

MultipleConnectionManager::MultipleConnectionManager() :
    _CurrentConnected(NULL)
{
    pthread_mutex_init(&_lock, NULL);
}

MultipleConnectionManager::~MultipleConnectionManager() {
    pthread_mutex_destroy(&_lock);
}

void MultipleConnectionManager::AddConnection(struct mod* mod) {
    if (mod == NULL) return;
        
    pthread_mutex_lock(&_lock);
    
    if (_CurrentConnected != NULL) {
        _CurrentConnected->connectionManager->Terminate();
    }
    
    pthread_mutex_unlock(&_lock);
    
    for (int i = 0; i < 10; i++) {
        if (_CurrentConnected == NULL) {
            break;
        }
        sleep(1);
    }
}

void MultipleConnectionManager::RemoveConnection() {
    pthread_mutex_lock(&_lock);

    _CurrentConnected = NULL;
    
    pthread_mutex_unlock(&_lock);
}
