#include <stdio.h>
#include "script-parse.h"
int main (int argc, char **argv)
{
        if (argc < 2) { fprintf (stderr, "usage: ply-script-check FILE\n"); return 2; }
        script_op_t *op = script_parse_file (argv[1]);
        if (op == NULL) { printf ("PARSE FAILED: %s\n", argv[1]); return 1; }
        printf ("PARSE OK: %s\n", argv[1]);
        return 0;
}
