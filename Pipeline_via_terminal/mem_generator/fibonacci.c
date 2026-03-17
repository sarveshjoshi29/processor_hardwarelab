int main(){
    int n = 7;
    int prev = 0;
    int curr = 1;
    if(n <= 1){
        return n;
    }
    
    for(int i =2;i<=n;i++){
        int temp = curr+prev;
        prev = curr;
        curr = temp;
    }
    return curr;
}