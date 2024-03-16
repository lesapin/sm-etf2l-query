import numpy as np

numCount = 17
numRange = 9

HEADER = "#if defined _bitstr64_included_\n    #endinput\n#endif\n#define _bitstr64_included_\n\n"

with open("bitstr64_{}x{}.inc".format(numCount, numRange), 'w', encoding="utf-8") as f:
    f.write(HEADER)
    f.write("#define BITSTR64_NUM_COUNT {}\n".format(numCount))
    f.write("#define BITSTR64_NUM_RANGE {}\n\n".format(numRange))

    arr = "bitstr64[{}][{}][2] =\n\t{{\n".format(numCount, numRange)
    shift = np.uint64(32)

    for row in range(0, numCount):
        multiplier = pow(10, row)
        #arr += "\t\t// {} - {}\n".format(multiplier, (numRange)*multiplier)
        arr += "\t\t{ "
        for col in range(1, numRange+1):
            num = np.uint64(col * multiplier)
            bitslo = np.right_shift(np.left_shift(num, shift), shift)
            bitshi = np.right_shift(num, shift)
            arr += "{{{},{}}}, ".format(bitshi, bitslo)
        arr += "},\n"
    arr += "\t}"
    
    f.write(arr)
