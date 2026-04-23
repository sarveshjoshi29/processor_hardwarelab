import struct, os

def bin_to_hex(bin_path, hex_path, max_words=1024):
    if not os.path.exists(bin_path):
        print(f"File {bin_path} not found. Creating empty hex.")
        data = b''
    else:
        with open(bin_path, "rb") as f:
            data = f.read()

    words = []
    # Pad to multiple of 4 bytes
    data += b'\x00' * ((4 - len(data) % 4) % 4)
    
    for i in range(0, len(data), 4):
        w = struct.unpack("<I", data[i:i+4])[0]
        words.append(w)
    
    # Pad to max_words to clear the rest of memory
    while len(words) < max_words:
        words.append(0)
    
    if len(words) > max_words:
        print(f"WARNING: {bin_path} is {len(words)} words long! Max is {max_words}.")
        words = words[:max_words]

    with open(hex_path, "w") as f:
        for w in words:
            f.write(f"{w:08x}\n")
    print(f"Generated {hex_path} ({max_words} words)")

base = "."
bin_to_hex("imem.bin", f"{base}/imem.hex", 1024)
bin_to_hex("dmem.bin", f"{base}/dmem.hex", 1024)
