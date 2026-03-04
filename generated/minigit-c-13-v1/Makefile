CC = gcc
CFLAGS = -O2 -Wall -Wextra
TARGET = minigit

all: $(TARGET)

$(TARGET): minigit.c
	$(CC) $(CFLAGS) -o $(TARGET) minigit.c

clean:
	rm -f $(TARGET)
