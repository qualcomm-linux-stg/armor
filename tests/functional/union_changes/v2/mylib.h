union Data {
    double f;                 // changed type from float to double
    char label[10];          // same
    long id;                 // added new member

    union nested_union {
        int code;
        int key; // Removed value and Added key
    };
    
};

// Changed order
union Alpha{
    int y;
    int x;
};