.text
.global _start
_start:
    mov  x0, #1
    adr  x1, message
    mov  x2, #17
    mov  x8, #64            // write
    svc  #0

    mov  x0, #0
    mov  x8, #93            // exit
    svc  #0

message:
    .ascii "hello from guest\n"
