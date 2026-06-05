
#include <sightglass.h>

#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define ITERATIONS 1000
#define LENGTH 10000

int main()
{
    size_t length = LENGTH;

    uint32_t *x;
    x = malloc(LENGTH * sizeof *x);
    assert(x != NULL);

    size_t i;
    for (i = (size_t)0U; i < length; i++)
    {
        x[i] = i;
    }

    printf("[switch] running switch statement for %d iterations on a %zu-byte string\n", ITERATIONS, length);
    bench_start();
    int j;
    for (j = 0; j < ITERATIONS; j++)
    {
        BLACK_BOX(x);
        BLACK_BOX(length);
        for (i = (size_t)0U; i < length; i++)
        {
            switch (x[i])
            {
            case 0:
                x[i] ^= 399;
                break;
            case 1:
                x[i] ^= 694;
                break;
            case 2:
                x[i] ^= 3492;
                break;
            case 3:
                x[i] ^= 178;
                break;
            case 4:
                x[i] ^= 2502;
                break;
            case 5:
                x[i] ^= 3860;
                break;
            case 6:
                x[i] ^= 3571;
                break;
            case 7:
                x[i] ^= 2405;
                break;
            case 8:
                x[i] ^= 1111;
                break;
            case 9:
                x[i] ^= 3855;
                break;
            case 10:
                x[i] ^= 1320;
                break;
            case 11:
                x[i] ^= 60;
                break;
            case 12:
                x[i] ^= 3924;
                break;
            case 13:
                x[i] ^= 848;
                break;
            case 14:
                x[i] ^= 3873;
                break;
            case 15:
                x[i] ^= 3852;
                break;
            case 16:
                x[i] ^= 1670;
                break;
            case 17:
                x[i] ^= 2344;
                break;
            case 18:
                x[i] ^= 3258;
                break;
            case 19:
                x[i] ^= 1308;
                break;
            case 20:
                x[i] ^= 2959;
                break;
            case 21:
                x[i] ^= 224;
                break;
            case 22:
                x[i] ^= 3613;
                break;
            case 23:
                x[i] ^= 2838;
                break;
            case 24:
                x[i] ^= 1722;
                break;
            case 25:
                x[i] ^= 1429;
                break;
            case 26:
                x[i] ^= 3521;
                break;
            case 27:
                x[i] ^= 2501;
                break;
            case 28:
                x[i] ^= 4006;
                break;
            case 29:
                x[i] ^= 2836;
                break;
            case 30:
                x[i] ^= 4009;
                break;
            case 31:
                x[i] ^= 460;
                break;
            case 32:
                x[i] ^= 1458;
                break;
            case 33:
                x[i] ^= 862;
                break;
            case 34:
                x[i] ^= 1143;
                break;
            case 35:
                x[i] ^= 2785;
                break;
            case 36:
                x[i] ^= 3637;
                break;
            case 37:
                x[i] ^= 3391;
                break;
            case 38:
                x[i] ^= 2094;
                break;
            case 39:
                x[i] ^= 2534;
                break;
            case 40:
                x[i] ^= 474;
                break;
            case 41:
                x[i] ^= 2521;
                break;
            case 42:
                x[i] ^= 2458;
                break;
            case 43:
                x[i] ^= 3871;
                break;
            case 44:
                x[i] ^= 400;
                break;
            case 45:
                x[i] ^= 3992;
                break;
            case 46:
                x[i] ^= 2251;
                break;
            case 47:
                x[i] ^= 153;
                break;
            case 48:
                x[i] ^= 1280;
                break;
            case 49:
                x[i] ^= 341;
                break;
            case 50:
                x[i] ^= 3709;
                break;
            case 51:
                x[i] ^= 420;
                break;
            case 52:
                x[i] ^= 911;
                break;
            case 53:
                x[i] ^= 247;
                break;
            case 54:
                x[i] ^= 2019;
                break;
            case 55:
                x[i] ^= 748;
                break;
            case 56:
                x[i] ^= 1510;
                break;
            case 57:
                x[i] ^= 1004;
                break;
            case 58:
                x[i] ^= 339;
                break;
            case 59:
                x[i] ^= 3011;
                break;
            case 60:
                x[i] ^= 162;
                break;
            case 61:
                x[i] ^= 1042;
                break;
            case 62:
                x[i] ^= 2650;
                break;
            case 63:
                x[i] ^= 4095;
                break;
            case 64:
                x[i] ^= 3883;
                break;
            case 65:
                x[i] ^= 1806;
                break;
            case 66:
                x[i] ^= 2308;
                break;
            case 67:
                x[i] ^= 2721;
                break;
            case 68:
                x[i] ^= 725;
                break;
            case 69:
                x[i] ^= 3015;
                break;
            case 70:
                x[i] ^= 303;
                break;
            case 71:
                x[i] ^= 2337;
                break;
            case 72:
                x[i] ^= 1381;
                break;
            case 73:
                x[i] ^= 1736;
                break;
            case 74:
                x[i] ^= 1697;
                break;
            case 75:
                x[i] ^= 1022;
                break;
            case 76:
                x[i] ^= 986;
                break;
            case 77:
                x[i] ^= 900;
                break;
            case 78:
                x[i] ^= 1319;
                break;
            case 79:
                x[i] ^= 1888;
                break;
            case 80:
                x[i] ^= 2474;
                break;
            case 81:
                x[i] ^= 3478;
                break;
            case 82:
                x[i] ^= 853;
                break;
            case 83:
                x[i] ^= 3467;
                break;
            case 84:
                x[i] ^= 1639;
                break;
            case 85:
                x[i] ^= 2867;
                break;
            case 86:
                x[i] ^= 2667;
                break;
            case 87:
                x[i] ^= 172;
                break;
            case 88:
                x[i] ^= 345;
                break;
            case 89:
                x[i] ^= 3386;
                break;
            case 90:
                x[i] ^= 2749;
                break;
            case 91:
                x[i] ^= 1630;
                break;
            case 92:
                x[i] ^= 2719;
                break;
            case 93:
                x[i] ^= 3636;
                break;
            case 94:
                x[i] ^= 2129;
                break;
            case 95:
                x[i] ^= 3470;
                break;
            case 96:
                x[i] ^= 271;
                break;
            case 97:
                x[i] ^= 158;
                break;
            case 98:
                x[i] ^= 1226;
                break;
            case 99:
                x[i] ^= 200;
                break;
            case 100:
                x[i] ^= 828;
                break;
            case 101:
                x[i] ^= 2902;
                break;
            case 102:
                x[i] ^= 3740;
                break;
            case 103:
                x[i] ^= 446;
                break;
            case 104:
                x[i] ^= 3629;
                break;
            case 105:
                x[i] ^= 2213;
                break;
            case 106:
                x[i] ^= 308;
                break;
            case 107:
                x[i] ^= 146;
                break;
            case 108:
                x[i] ^= 3998;
                break;
            case 109:
                x[i] ^= 1264;
                break;
            case 110:
                x[i] ^= 3929;
                break;
            case 111:
                x[i] ^= 206;
                break;
            case 112:
                x[i] ^= 3293;
                break;
            case 113:
                x[i] ^= 2460;
                break;
            case 114:
                x[i] ^= 370;
                break;
            case 115:
                x[i] ^= 2469;
                break;
            case 116:
                x[i] ^= 2196;
                break;
            case 117:
                x[i] ^= 2416;
                break;
            case 118:
                x[i] ^= 1388;
                break;
            case 119:
                x[i] ^= 682;
                break;
            case 120:
                x[i] ^= 3192;
                break;
            case 121:
                x[i] ^= 207;
                break;
            case 122:
                x[i] ^= 1285;
                break;
            case 123:
                x[i] ^= 1302;
                break;
            case 124:
                x[i] ^= 3181;
                break;
            case 125:
                x[i] ^= 2917;
                break;
            case 126:
                x[i] ^= 1601;
                break;
            case 127:
                x[i] ^= 1502;
                break;
            case 128:
                x[i] ^= 2399;
                break;
            case 129:
                x[i] ^= 2767;
                break;
            case 130:
                x[i] ^= 361;
                break;
            case 131:
                x[i] ^= 374;
                break;
            case 132:
                x[i] ^= 1650;
                break;
            case 133:
                x[i] ^= 3471;
                break;
            case 134:
                x[i] ^= 1128;
                break;
            case 135:
                x[i] ^= 3441;
                break;
            case 136:
                x[i] ^= 868;
                break;
            case 137:
                x[i] ^= 2607;
                break;
            case 138:
                x[i] ^= 2577;
                break;
            case 139:
                x[i] ^= 4012;
                break;
            case 140:
                x[i] ^= 981;
                break;
            case 141:
                x[i] ^= 1471;
                break;
            case 142:
                x[i] ^= 745;
                break;
            case 143:
                x[i] ^= 3716;
                break;
            case 144:
                x[i] ^= 968;
                break;
            case 145:
                x[i] ^= 493;
                break;
            case 146:
                x[i] ^= 2374;
                break;
            case 147:
                x[i] ^= 2478;
                break;
            case 148:
                x[i] ^= 3340;
                break;
            case 149:
                x[i] ^= 154;
                break;
            case 150:
                x[i] ^= 1347;
                break;
            case 151:
                x[i] ^= 3077;
                break;
            case 152:
                x[i] ^= 689;
                break;
            case 153:
                x[i] ^= 2723;
                break;
            case 154:
                x[i] ^= 3691;
                break;
            case 155:
                x[i] ^= 3451;
                break;
            case 156:
                x[i] ^= 3410;
                break;
            case 157:
                x[i] ^= 4056;
                break;
            case 158:
                x[i] ^= 2894;
                break;
            case 159:
                x[i] ^= 1484;
                break;
            case 160:
                x[i] ^= 2000;
                break;
            case 161:
                x[i] ^= 1424;
                break;
            case 162:
                x[i] ^= 2459;
                break;
            case 163:
                x[i] ^= 2260;
                break;
            case 164:
                x[i] ^= 3518;
                break;
            case 165:
                x[i] ^= 1439;
                break;
            case 166:
                x[i] ^= 3527;
                break;
            case 167:
                x[i] ^= 188;
                break;
            case 168:
                x[i] ^= 3231;
                break;
            case 169:
                x[i] ^= 1981;
                break;
            case 170:
                x[i] ^= 953;
                break;
            case 171:
                x[i] ^= 3872;
                break;
            case 172:
                x[i] ^= 2130;
                break;
            case 173:
                x[i] ^= 83;
                break;
            case 174:
                x[i] ^= 65;
                break;
            case 175:
                x[i] ^= 534;
                break;
            case 176:
                x[i] ^= 2895;
                break;
            case 177:
                x[i] ^= 1433;
                break;
            case 178:
                x[i] ^= 1552;
                break;
            case 179:
                x[i] ^= 1165;
                break;
            case 180:
                x[i] ^= 1229;
                break;
            case 181:
                x[i] ^= 1049;
                break;
            case 182:
                x[i] ^= 3646;
                break;
            case 183:
                x[i] ^= 1544;
                break;
            case 184:
                x[i] ^= 1125;
                break;
            case 185:
                x[i] ^= 2484;
                break;
            case 186:
                x[i] ^= 588;
                break;
            case 187:
                x[i] ^= 1528;
                break;
            case 188:
                x[i] ^= 1142;
                break;
            case 189:
                x[i] ^= 3066;
                break;
            case 190:
                x[i] ^= 774;
                break;
            case 191:
                x[i] ^= 461;
                break;
            case 192:
                x[i] ^= 3870;
                break;
            case 193:
                x[i] ^= 1211;
                break;
            case 194:
                x[i] ^= 3994;
                break;
            case 195:
                x[i] ^= 753;
                break;
            case 196:
                x[i] ^= 357;
                break;
            case 197:
                x[i] ^= 395;
                break;
            case 198:
                x[i] ^= 1682;
                break;
            case 199:
                x[i] ^= 829;
                break;
            case 200:
                x[i] ^= 3089;
                break;
            case 201:
                x[i] ^= 3222;
                break;
            case 202:
                x[i] ^= 3975;
                break;
            case 203:
                x[i] ^= 1731;
                break;
            case 204:
                x[i] ^= 3415;
                break;
            case 205:
                x[i] ^= 2430;
                break;
            case 206:
                x[i] ^= 1213;
                break;
            case 207:
                x[i] ^= 4003;
                break;
            case 208:
                x[i] ^= 784;
                break;
            case 209:
                x[i] ^= 253;
                break;
            case 210:
                x[i] ^= 3624;
                break;
            case 211:
                x[i] ^= 898;
                break;
            case 212:
                x[i] ^= 3433;
                break;
            case 213:
                x[i] ^= 2745;
                break;
            case 214:
                x[i] ^= 323;
                break;
            case 215:
                x[i] ^= 764;
                break;
            case 216:
                x[i] ^= 2199;
                break;
            case 217:
                x[i] ^= 3360;
                break;
            case 218:
                x[i] ^= 2209;
                break;
            case 219:
                x[i] ^= 1322;
                break;
            case 220:
                x[i] ^= 1426;
                break;
            case 221:
                x[i] ^= 3824;
                break;
            case 222:
                x[i] ^= 141;
                break;
            case 223:
                x[i] ^= 1556;
                break;
            case 224:
                x[i] ^= 2860;
                break;
            case 225:
                x[i] ^= 3777;
                break;
            case 226:
                x[i] ^= 1029;
                break;
            case 227:
                x[i] ^= 1073;
                break;
            case 228:
                x[i] ^= 874;
                break;
            case 229:
                x[i] ^= 883;
                break;
            case 230:
                x[i] ^= 107;
                break;
            case 231:
                x[i] ^= 3877;
                break;
            case 232:
                x[i] ^= 313;
                break;
            case 233:
                x[i] ^= 354;
                break;
            case 234:
                x[i] ^= 1956;
                break;
            case 235:
                x[i] ^= 1677;
                break;
            case 236:
                x[i] ^= 545;
                break;
            case 237:
                x[i] ^= 888;
                break;
            case 238:
                x[i] ^= 1704;
                break;
            case 239:
                x[i] ^= 3369;
                break;
            case 240:
                x[i] ^= 2291;
                break;
            case 241:
                x[i] ^= 3508;
                break;
            case 242:
                x[i] ^= 3878;
                break;
            case 243:
                x[i] ^= 382;
                break;
            case 244:
                x[i] ^= 3822;
                break;
            case 245:
                x[i] ^= 3134;
                break;
            case 246:
                x[i] ^= 3903;
                break;
            case 247:
                x[i] ^= 844;
                break;
            case 248:
                x[i] ^= 3603;
                break;
            case 249:
                x[i] ^= 3816;
                break;
            case 250:
                x[i] ^= 2908;
                break;
            case 251:
                x[i] ^= 2833;
                break;
            case 252:
                x[i] ^= 2266;
                break;
            case 253:
                x[i] ^= 3724;
                break;
            case 254:
                x[i] ^= 2532;
                break;
            case 255:
                x[i] ^= 307;
                break;
            case 256:
                x[i] ^= 2777;
                break;
            case 257:
                x[i] ^= 239;
                break;
            case 258:
                x[i] ^= 2033;
                break;
            case 259:
                x[i] ^= 1178;
                break;
            case 260:
                x[i] ^= 2073;
                break;
            case 261:
                x[i] ^= 1436;
                break;
            case 262:
                x[i] ^= 1334;
                break;
            case 263:
                x[i] ^= 2855;
                break;
            case 264:
                x[i] ^= 2877;
                break;
            case 265:
                x[i] ^= 2372;
                break;
            case 266:
                x[i] ^= 2553;
                break;
            case 267:
                x[i] ^= 2885;
                break;
            case 268:
                x[i] ^= 2133;
                break;
            case 269:
                x[i] ^= 2470;
                break;
            case 270:
                x[i] ^= 91;
                break;
            case 271:
                x[i] ^= 4091;
                break;
            case 272:
                x[i] ^= 2519;
                break;
            case 273:
                x[i] ^= 1879;
                break;
            case 274:
                x[i] ^= 3074;
                break;
            case 275:
                x[i] ^= 1541;
                break;
            case 276:
                x[i] ^= 3164;
                break;
            case 277:
                x[i] ^= 150;
                break;
            case 278:
                x[i] ^= 394;
                break;
            case 279:
                x[i] ^= 1546;
                break;
            case 280:
                x[i] ^= 3807;
                break;
            case 281:
                x[i] ^= 3918;
                break;
            case 282:
                x[i] ^= 1564;
                break;
            case 283:
                x[i] ^= 3599;
                break;
            case 284:
                x[i] ^= 1707;
                break;
            case 285:
                x[i] ^= 2115;
                break;
            case 286:
                x[i] ^= 2006;
                break;
            case 287:
                x[i] ^= 1304;
                break;
            case 288:
                x[i] ^= 982;
                break;
            case 289:
                x[i] ^= 3573;
                break;
            case 290:
                x[i] ^= 5;
                break;
            case 291:
                x[i] ^= 664;
                break;
            case 292:
                x[i] ^= 1481;
                break;
            case 293:
                x[i] ^= 785;
                break;
            case 294:
                x[i] ^= 3546;
                break;
            case 295:
                x[i] ^= 1873;
                break;
            case 296:
                x[i] ^= 3868;
                break;
            case 297:
                x[i] ^= 67;
                break;
            case 298:
                x[i] ^= 2956;
                break;
            case 299:
                x[i] ^= 3259;
                break;
            case 300:
                x[i] ^= 3848;
                break;
            case 301:
                x[i] ^= 2933;
                break;
            case 302:
                x[i] ^= 1713;
                break;
            case 303:
                x[i] ^= 2578;
                break;
            case 304:
                x[i] ^= 584;
                break;
            case 305:
                x[i] ^= 1766;
                break;
            case 306:
                x[i] ^= 144;
                break;
            case 307:
                x[i] ^= 660;
                break;
            case 308:
                x[i] ^= 2105;
                break;
            case 309:
                x[i] ^= 3605;
                break;
            case 310:
                x[i] ^= 667;
                break;
            case 311:
                x[i] ^= 723;
                break;
            case 312:
                x[i] ^= 3820;
                break;
            case 313:
                x[i] ^= 3346;
                break;
            case 314:
                x[i] ^= 1329;
                break;
            case 315:
                x[i] ^= 1841;
                break;
            case 316:
                x[i] ^= 3238;
                break;
            case 317:
                x[i] ^= 3796;
                break;
            case 318:
                x[i] ^= 2275;
                break;
            case 319:
                x[i] ^= 904;
                break;
            case 320:
                x[i] ^= 703;
                break;
            case 321:
                x[i] ^= 283;
                break;
            case 322:
                x[i] ^= 2321;
                break;
            case 323:
                x[i] ^= 536;
                break;
            case 324:
                x[i] ^= 2725;
                break;
            case 325:
                x[i] ^= 877;
                break;
            case 326:
                x[i] ^= 3177;
                break;
            case 327:
                x[i] ^= 935;
                break;
            case 328:
                x[i] ^= 780;
                break;
            case 329:
                x[i] ^= 1902;
                break;
            case 330:
                x[i] ^= 697;
                break;
            case 331:
                x[i] ^= 21;
                break;
            case 332:
                x[i] ^= 1706;
                break;
            case 333:
                x[i] ^= 1592;
                break;
            case 334:
                x[i] ^= 349;
                break;
            case 335:
                x[i] ^= 943;
                break;
            case 336:
                x[i] ^= 2016;
                break;
            case 337:
                x[i] ^= 3768;
                break;
            case 338:
                x[i] ^= 1529;
                break;
            case 339:
                x[i] ^= 560;
                break;
            case 340:
                x[i] ^= 3084;
                break;
            case 341:
                x[i] ^= 2678;
                break;
            case 342:
                x[i] ^= 1523;
                break;
            case 343:
                x[i] ^= 1089;
                break;
            case 344:
                x[i] ^= 2954;
                break;
            case 345:
                x[i] ^= 2522;
                break;
            case 346:
                x[i] ^= 33;
                break;
            case 347:
                x[i] ^= 1244;
                break;
            case 348:
                x[i] ^= 1811;
                break;
            case 349:
                x[i] ^= 1580;
                break;
            case 350:
                x[i] ^= 2025;
                break;
            case 351:
                x[i] ^= 1274;
                break;
            case 352:
                x[i] ^= 2794;
                break;
            case 353:
                x[i] ^= 2883;
                break;
            case 354:
                x[i] ^= 2254;
                break;
            case 355:
                x[i] ^= 3121;
                break;
            case 356:
                x[i] ^= 1207;
                break;
            case 357:
                x[i] ^= 655;
                break;
            case 358:
                x[i] ^= 2595;
                break;
            case 359:
                x[i] ^= 1130;
                break;
            case 360:
                x[i] ^= 417;
                break;
            case 361:
                x[i] ^= 2261;
                break;
            case 362:
                x[i] ^= 1715;
                break;
            case 363:
                x[i] ^= 434;
                break;
            case 364:
                x[i] ^= 359;
                break;
            case 365:
                x[i] ^= 53;
                break;
            case 366:
                x[i] ^= 2055;
                break;
            case 367:
                x[i] ^= 1032;
                break;
            case 368:
                x[i] ^= 1053;
                break;
            case 369:
                x[i] ^= 1641;
                break;
            case 370:
                x[i] ^= 2654;
                break;
            case 371:
                x[i] ^= 433;
                break;
            case 372:
                x[i] ^= 1794;
                break;
            case 373:
                x[i] ^= 3440;
                break;
            case 374:
                x[i] ^= 23;
                break;
            case 375:
                x[i] ^= 4;
                break;
            case 376:
                x[i] ^= 2793;
                break;
            case 377:
                x[i] ^= 3733;
                break;
            case 378:
                x[i] ^= 3210;
                break;
            case 379:
                x[i] ^= 3662;
                break;
            case 380:
                x[i] ^= 3301;
                break;
            case 381:
                x[i] ^= 1396;
                break;
            case 382:
                x[i] ^= 1760;
                break;
            case 383:
                x[i] ^= 3862;
                break;
            case 384:
                x[i] ^= 3993;
                break;
            case 385:
                x[i] ^= 1748;
                break;
            case 386:
                x[i] ^= 3109;
                break;
            case 387:
                x[i] ^= 2239;
                break;
            case 388:
                x[i] ^= 2715;
                break;
            case 389:
                x[i] ^= 527;
                break;
            case 390:
                x[i] ^= 3239;
                break;
            case 391:
                x[i] ^= 587;
                break;
            case 392:
                x[i] ^= 3092;
                break;
            case 393:
                x[i] ^= 191;
                break;
            case 394:
                x[i] ^= 2435;
                break;
            case 395:
                x[i] ^= 3818;
                break;
            case 396:
                x[i] ^= 3826;
                break;
            case 397:
                x[i] ^= 2231;
                break;
            case 398:
                x[i] ^= 3935;
                break;
            case 399:
                x[i] ^= 1208;
                break;
            case 400:
                x[i] ^= 2018;
                break;
            case 401:
                x[i] ^= 840;
                break;
            case 402:
                x[i] ^= 3248;
                break;
            case 403:
                x[i] ^= 2763;
                break;
            case 404:
                x[i] ^= 3431;
                break;
            case 405:
                x[i] ^= 2846;
                break;
            case 406:
                x[i] ^= 3264;
                break;
            case 407:
                x[i] ^= 959;
                break;
            case 408:
                x[i] ^= 2143;
                break;
            case 409:
                x[i] ^= 2835;
                break;
            case 410:
                x[i] ^= 25;
                break;
            case 411:
                x[i] ^= 3885;
                break;
            case 412:
                x[i] ^= 1189;
                break;
            case 413:
                x[i] ^= 855;
                break;
            case 414:
                x[i] ^= 533;
                break;
            case 415:
                x[i] ^= 3183;
                break;
            case 416:
                x[i] ^= 2396;
                break;
            case 417:
                x[i] ^= 164;
                break;
            case 418:
                x[i] ^= 1574;
                break;
            case 419:
                x[i] ^= 4021;
                break;
            case 420:
                x[i] ^= 1013;
                break;
            case 421:
                x[i] ^= 2991;
                break;
            case 422:
                x[i] ^= 1187;
                break;
            case 423:
                x[i] ^= 936;
                break;
            case 424:
                x[i] ^= 1441;
                break;
            case 425:
                x[i] ^= 3132;
                break;
            case 426:
                x[i] ^= 3817;
                break;
            case 427:
                x[i] ^= 226;
                break;
            case 428:
                x[i] ^= 4055;
                break;
            case 429:
                x[i] ^= 3568;
                break;
            case 430:
                x[i] ^= 2634;
                break;
            case 431:
                x[i] ^= 1238;
                break;
            case 432:
                x[i] ^= 1016;
                break;
            case 433:
                x[i] ^= 2172;
                break;
            case 434:
                x[i] ^= 1719;
                break;
            case 435:
                x[i] ^= 1509;
                break;
            case 436:
                x[i] ^= 3178;
                break;
            case 437:
                x[i] ^= 2909;
                break;
            case 438:
                x[i] ^= 1634;
                break;
            case 439:
                x[i] ^= 142;
                break;
            case 440:
                x[i] ^= 752;
                break;
            case 441:
                x[i] ^= 2361;
                break;
            case 442:
                x[i] ^= 3114;
                break;
            case 443:
                x[i] ^= 3526;
                break;
            case 444:
                x[i] ^= 3296;
                break;
            case 445:
                x[i] ^= 1074;
                break;
            case 446:
                x[i] ^= 1062;
                break;
            case 447:
                x[i] ^= 119;
                break;
            case 448:
                x[i] ^= 2628;
                break;
            case 449:
                x[i] ^= 1965;
                break;
            case 450:
                x[i] ^= 2612;
                break;
            case 451:
                x[i] ^= 2310;
                break;
            case 452:
                x[i] ^= 2904;
                break;
            case 453:
                x[i] ^= 3275;
                break;
            case 454:
                x[i] ^= 1339;
                break;
            case 455:
                x[i] ^= 3358;
                break;
            case 456:
                x[i] ^= 2791;
                break;
            case 457:
                x[i] ^= 12;
                break;
            case 458:
                x[i] ^= 371;
                break;
            case 459:
                x[i] ^= 2038;
                break;
            case 460:
                x[i] ^= 301;
                break;
            case 461:
                x[i] ^= 476;
                break;
            case 462:
                x[i] ^= 1363;
                break;
            case 463:
                x[i] ^= 2084;
                break;
            case 464:
                x[i] ^= 677;
                break;
            case 465:
                x[i] ^= 1366;
                break;
            case 466:
                x[i] ^= 1955;
                break;
            case 467:
                x[i] ^= 269;
                break;
            case 468:
                x[i] ^= 972;
                break;
            case 469:
                x[i] ^= 2798;
                break;
            case 470:
                x[i] ^= 1406;
                break;
            case 471:
                x[i] ^= 4058;
                break;
            case 472:
                x[i] ^= 2948;
                break;
            case 473:
                x[i] ^= 3250;
                break;
            case 474:
                x[i] ^= 1083;
                break;
            case 475:
                x[i] ^= 1496;
                break;
            case 476:
                x[i] ^= 1847;
                break;
            case 477:
                x[i] ^= 3988;
                break;
            case 478:
                x[i] ^= 699;
                break;
            case 479:
                x[i] ^= 2982;
                break;
            case 480:
                x[i] ^= 1278;
                break;
            case 481:
                x[i] ^= 3180;
                break;
            case 482:
                x[i] ^= 1910;
                break;
            case 483:
                x[i] ^= 800;
                break;
            case 484:
                x[i] ^= 766;
                break;
            case 485:
                x[i] ^= 3723;
                break;
            case 486:
                x[i] ^= 18;
                break;
            case 487:
                x[i] ^= 3616;
                break;
            case 488:
                x[i] ^= 3350;
                break;
            case 489:
                x[i] ^= 2708;
                break;
            case 490:
                x[i] ^= 3727;
                break;
            case 491:
                x[i] ^= 377;
                break;
            case 492:
                x[i] ^= 3007;
                break;
            case 493:
                x[i] ^= 2114;
                break;
            case 494:
                x[i] ^= 1116;
                break;
            case 495:
                x[i] ^= 3006;
                break;
            case 496:
                x[i] ^= 1762;
                break;
            case 497:
                x[i] ^= 3395;
                break;
            case 498:
                x[i] ^= 1796;
                break;
            case 499:
                x[i] ^= 2176;
                break;
            case 500:
                x[i] ^= 2227;
                break;
            case 501:
                x[i] ^= 487;
                break;
            case 502:
                x[i] ^= 2778;
                break;
            case 503:
                x[i] ^= 648;
                break;
            case 504:
                x[i] ^= 3717;
                break;
            case 505:
                x[i] ^= 1199;
                break;
            case 506:
                x[i] ^= 3653;
                break;
            case 507:
                x[i] ^= 3682;
                break;
            case 508:
                x[i] ^= 500;
                break;
            case 509:
                x[i] ^= 2845;
                break;
            case 510:
                x[i] ^= 1194;
                break;
            case 511:
                x[i] ^= 586;
                break;
            case 512:
                x[i] ^= 3274;
                break;
            case 513:
                x[i] ^= 229;
                break;
            case 514:
                x[i] ^= 1382;
                break;
            case 515:
                x[i] ^= 100;
                break;
            case 516:
                x[i] ^= 891;
                break;
            case 517:
                x[i] ^= 3562;
                break;
            case 518:
                x[i] ^= 1287;
                break;
            case 519:
                x[i] ^= 1031;
                break;
            case 520:
                x[i] ^= 2660;
                break;
            case 521:
                x[i] ^= 1856;
                break;
            case 522:
                x[i] ^= 1652;
                break;
            case 523:
                x[i] ^= 3908;
                break;
            case 524:
                x[i] ^= 3247;
                break;
            case 525:
                x[i] ^= 1474;
                break;
            case 526:
                x[i] ^= 3945;
                break;
            case 527:
                x[i] ^= 1352;
                break;
            case 528:
                x[i] ^= 3030;
                break;
            case 529:
                x[i] ^= 2288;
                break;
            case 530:
                x[i] ^= 3080;
                break;
            case 531:
                x[i] ^= 438;
                break;
            case 532:
                x[i] ^= 1046;
                break;
            case 533:
                x[i] ^= 1033;
                break;
            case 534:
                x[i] ^= 1328;
                break;
            case 535:
                x[i] ^= 1572;
                break;
            case 536:
                x[i] ^= 3188;
                break;
            case 537:
                x[i] ^= 3145;
                break;
            case 538:
                x[i] ^= 2299;
                break;
            case 539:
                x[i] ^= 1831;
                break;
            case 540:
                x[i] ^= 771;
                break;
            case 541:
                x[i] ^= 3363;
                break;
            case 542:
                x[i] ^= 338;
                break;
            case 543:
                x[i] ^= 3537;
                break;
            case 544:
                x[i] ^= 2726;
                break;
            case 545:
                x[i] ^= 956;
                break;
            case 546:
                x[i] ^= 905;
                break;
            case 547:
                x[i] ^= 2249;
                break;
            case 548:
                x[i] ^= 1218;
                break;
            case 549:
                x[i] ^= 3936;
                break;
            case 550:
                x[i] ^= 672;
                break;
            case 551:
                x[i] ^= 2687;
                break;
            case 552:
                x[i] ^= 3052;
                break;
            case 553:
                x[i] ^= 676;
                break;
            case 554:
                x[i] ^= 504;
                break;
            case 555:
                x[i] ^= 3213;
                break;
            case 556:
                x[i] ^= 826;
                break;
            case 557:
                x[i] ^= 346;
                break;
            case 558:
                x[i] ^= 944;
                break;
            case 559:
                x[i] ^= 1566;
                break;
            case 560:
                x[i] ^= 2340;
                break;
            case 561:
                x[i] ^= 566;
                break;
            case 562:
                x[i] ^= 749;
                break;
            case 563:
                x[i] ^= 3223;
                break;
            case 564:
                x[i] ^= 386;
                break;
            case 565:
                x[i] ^= 2523;
                break;
            case 566:
                x[i] ^= 3037;
                break;
            case 567:
                x[i] ^= 837;
                break;
            case 568:
                x[i] ^= 1499;
                break;
            case 569:
                x[i] ^= 246;
                break;
            case 570:
                x[i] ^= 2184;
                break;
            case 571:
                x[i] ^= 1072;
                break;
            case 572:
                x[i] ^= 3695;
                break;
            case 573:
                x[i] ^= 97;
                break;
            case 574:
                x[i] ^= 3749;
                break;
            case 575:
                x[i] ^= 1144;
                break;
            case 576:
                x[i] ^= 2622;
                break;
            case 577:
                x[i] ^= 2408;
                break;
            case 578:
                x[i] ^= 831;
                break;
            case 579:
                x[i] ^= 1994;
                break;
            case 580:
                x[i] ^= 1468;
                break;
            case 581:
                x[i] ^= 3434;
                break;
            case 582:
                x[i] ^= 1030;
                break;
            case 583:
                x[i] ^= 3766;
                break;
            case 584:
                x[i] ^= 3970;
                break;
            case 585:
                x[i] ^= 856;
                break;
            case 586:
                x[i] ^= 2582;
                break;
            case 587:
                x[i] ^= 1267;
                break;
            case 588:
                x[i] ^= 3510;
                break;
            case 589:
                x[i] ^= 3655;
                break;
            case 590:
                x[i] ^= 2142;
                break;
            case 591:
                x[i] ^= 925;
                break;
            case 592:
                x[i] ^= 3774;
                break;
            case 593:
                x[i] ^= 1336;
                break;
            case 594:
                x[i] ^= 3477;
                break;
            case 595:
                x[i] ^= 3672;
                break;
            case 596:
                x[i] ^= 3422;
                break;
            case 597:
                x[i] ^= 561;
                break;
            case 598:
                x[i] ^= 512;
                break;
            case 599:
                x[i] ^= 3640;
                break;
            case 600:
                x[i] ^= 1683;
                break;
            case 601:
                x[i] ^= 3594;
                break;
            case 602:
                x[i] ^= 372;
                break;
            case 603:
                x[i] ^= 2162;
                break;
            case 604:
                x[i] ^= 2916;
                break;
            case 605:
                x[i] ^= 942;
                break;
            case 606:
                x[i] ^= 2507;
                break;
            case 607:
                x[i] ^= 1003;
                break;
            case 608:
                x[i] ^= 2743;
                break;
            case 609:
                x[i] ^= 2393;
                break;
            case 610:
                x[i] ^= 3067;
                break;
            case 611:
                x[i] ^= 459;
                break;
            case 612:
                x[i] ^= 3619;
                break;
            case 613:
                x[i] ^= 1250;
                break;
            case 614:
                x[i] ^= 1311;
                break;
            case 615:
                x[i] ^= 934;
                break;
            case 616:
                x[i] ^= 1277;
                break;
            case 617:
                x[i] ^= 4049;
                break;
            case 618:
                x[i] ^= 2990;
                break;
            case 619:
                x[i] ^= 118;
                break;
            case 620:
                x[i] ^= 2269;
                break;
            case 621:
                x[i] ^= 1297;
                break;
            case 622:
                x[i] ^= 3;
                break;
            case 623:
                x[i] ^= 1038;
                break;
            case 624:
                x[i] ^= 289;
                break;
            case 625:
                x[i] ^= 1885;
                break;
            case 626:
                x[i] ^= 2366;
                break;
            case 627:
                x[i] ^= 3423;
                break;
            case 628:
                x[i] ^= 3076;
                break;
            case 629:
                x[i] ^= 3327;
                break;
            case 630:
                x[i] ^= 1620;
                break;
            case 631:
                x[i] ^= 3829;
                break;
            case 632:
                x[i] ^= 1973;
                break;
            case 633:
                x[i] ^= 902;
                break;
            case 634:
                x[i] ^= 3425;
                break;
            case 635:
                x[i] ^= 583;
                break;
            case 636:
                x[i] ^= 632;
                break;
            case 637:
                x[i] ^= 2563;
                break;
            case 638:
                x[i] ^= 2913;
                break;
            case 639:
                x[i] ^= 3858;
                break;
            case 640:
                x[i] ^= 1056;
                break;
            case 641:
                x[i] ^= 1052;
                break;
            case 642:
                x[i] ^= 1567;
                break;
            case 643:
                x[i] ^= 653;
                break;
            case 644:
                x[i] ^= 3692;
                break;
            case 645:
                x[i] ^= 3311;
                break;
            case 646:
                x[i] ^= 1616;
                break;
            case 647:
                x[i] ^= 1989;
                break;
            case 648:
                x[i] ^= 963;
                break;
            case 649:
                x[i] ^= 3396;
                break;
            case 650:
                x[i] ^= 1978;
                break;
            case 651:
                x[i] ^= 591;
                break;
            case 652:
                x[i] ^= 2216;
                break;
            case 653:
                x[i] ^= 924;
                break;
            case 654:
                x[i] ^= 194;
                break;
            case 655:
                x[i] ^= 732;
                break;
            case 656:
                x[i] ^= 692;
                break;
            case 657:
                x[i] ^= 2500;
                break;
            case 658:
                x[i] ^= 2336;
                break;
            case 659:
                x[i] ^= 615;
                break;
            case 660:
                x[i] ^= 685;
                break;
            case 661:
                x[i] ^= 41;
                break;
            case 662:
                x[i] ^= 3202;
                break;
            case 663:
                x[i] ^= 553;
                break;
            case 664:
                x[i] ^= 2976;
                break;
            case 665:
                x[i] ^= 1084;
                break;
            case 666:
                x[i] ^= 1767;
                break;
            case 667:
                x[i] ^= 3759;
                break;
            case 668:
                x[i] ^= 1576;
                break;
            case 669:
                x[i] ^= 3493;
                break;
            case 670:
                x[i] ^= 27;
                break;
            case 671:
                x[i] ^= 1657;
                break;
            case 672:
                x[i] ^= 3257;
                break;
            case 673:
                x[i] ^= 3126;
                break;
            case 674:
                x[i] ^= 3623;
                break;
            case 675:
                x[i] ^= 3742;
                break;
            case 676:
                x[i] ^= 552;
                break;
            case 677:
                x[i] ^= 1294;
                break;
            case 678:
                x[i] ^= 1983;
                break;
            case 679:
                x[i] ^= 726;
                break;
            case 680:
                x[i] ^= 1797;
                break;
            case 681:
                x[i] ^= 554;
                break;
            case 682:
                x[i] ^= 3867;
                break;
            case 683:
                x[i] ^= 2978;
                break;
            case 684:
                x[i] ^= 2697;
                break;
            case 685:
                x[i] ^= 2429;
                break;
            case 686:
                x[i] ^= 3788;
                break;
            case 687:
                x[i] ^= 618;
                break;
            case 688:
                x[i] ^= 3056;
                break;
            case 689:
                x[i] ^= 2963;
                break;
            case 690:
                x[i] ^= 1303;
                break;
            case 691:
                x[i] ^= 2889;
                break;
            case 692:
                x[i] ^= 2072;
                break;
            case 693:
                x[i] ^= 4051;
                break;
            case 694:
                x[i] ^= 2456;
                break;
            case 695:
                x[i] ^= 3853;
                break;
            case 696:
                x[i] ^= 1765;
                break;
            case 697:
                x[i] ^= 2050;
                break;
            case 698:
                x[i] ^= 34;
                break;
            case 699:
                x[i] ^= 511;
                break;
            case 700:
                x[i] ^= 294;
                break;
            case 701:
                x[i] ^= 3203;
                break;
            case 702:
                x[i] ^= 696;
                break;
            case 703:
                x[i] ^= 3548;
                break;
            case 704:
                x[i] ^= 181;
                break;
            case 705:
                x[i] ^= 913;
                break;
            case 706:
                x[i] ^= 3751;
                break;
            case 707:
                x[i] ^= 1249;
                break;
            case 708:
                x[i] ^= 2748;
                break;
            case 709:
                x[i] ^= 2293;
                break;
            case 710:
                x[i] ^= 3525;
                break;
            case 711:
                x[i] ^= 3802;
                break;
            case 712:
                x[i] ^= 3379;
                break;
            case 713:
                x[i] ^= 3149;
                break;
            case 714:
                x[i] ^= 3394;
                break;
            case 715:
                x[i] ^= 3834;
                break;
            case 716:
                x[i] ^= 2641;
                break;
            case 717:
                x[i] ^= 2606;
                break;
            case 718:
                x[i] ^= 686;
                break;
            case 719:
                x[i] ^= 281;
                break;
            case 720:
                x[i] ^= 1539;
                break;
            case 721:
                x[i] ^= 276;
                break;
            case 722:
                x[i] ^= 989;
                break;
            case 723:
                x[i] ^= 275;
                break;
            case 724:
                x[i] ^= 3404;
                break;
            case 725:
                x[i] ^= 782;
                break;
            case 726:
                x[i] ^= 1750;
                break;
            case 727:
                x[i] ^= 55;
                break;
            case 728:
                x[i] ^= 980;
                break;
            case 729:
                x[i] ^= 2938;
                break;
            case 730:
                x[i] ^= 2882;
                break;
            case 731:
                x[i] ^= 1941;
                break;
            case 732:
                x[i] ^= 1864;
                break;
            case 733:
                x[i] ^= 2301;
                break;
            case 734:
                x[i] ^= 3940;
                break;
            case 735:
                x[i] ^= 2303;
                break;
            case 736:
                x[i] ^= 1070;
                break;
            case 737:
                x[i] ^= 3462;
                break;
            case 738:
                x[i] ^= 2;
                break;
            case 739:
                x[i] ^= 3138;
                break;
            case 740:
                x[i] ^= 2579;
                break;
            case 741:
                x[i] ^= 3847;
                break;
            case 742:
                x[i] ^= 2248;
                break;
            case 743:
                x[i] ^= 3764;
                break;
            case 744:
                x[i] ^= 2292;
                break;
            case 745:
                x[i] ^= 2304;
                break;
            case 746:
                x[i] ^= 116;
                break;
            case 747:
                x[i] ^= 193;
                break;
            case 748:
                x[i] ^= 1041;
                break;
            case 749:
                x[i] ^= 1754;
                break;
            case 750:
                x[i] ^= 72;
                break;
            case 751:
                x[i] ^= 3333;
                break;
            case 752:
                x[i] ^= 1963;
                break;
            case 753:
                x[i] ^= 1774;
                break;
            case 754:
                x[i] ^= 3411;
                break;
            case 755:
                x[i] ^= 2148;
                break;
            case 756:
                x[i] ^= 3738;
                break;
            case 757:
                x[i] ^= 3980;
                break;
            case 758:
                x[i] ^= 2141;
                break;
            case 759:
                x[i] ^= 3199;
                break;
            case 760:
                x[i] ^= 2448;
                break;
            case 761:
                x[i] ^= 2046;
                break;
            case 762:
                x[i] ^= 1168;
                break;
            case 763:
                x[i] ^= 3053;
                break;
            case 764:
                x[i] ^= 1245;
                break;
            case 765:
                x[i] ^= 3514;
                break;
            case 766:
                x[i] ^= 1977;
                break;
            case 767:
                x[i] ^= 492;
                break;
            case 768:
                x[i] ^= 2388;
                break;
            case 769:
                x[i] ^= 585;
                break;
            case 770:
                x[i] ^= 1503;
                break;
            case 771:
                x[i] ^= 3699;
                break;
            case 772:
                x[i] ^= 368;
                break;
            case 773:
                x[i] ^= 3658;
                break;
            case 774:
                x[i] ^= 1562;
                break;
            case 775:
                x[i] ^= 108;
                break;
            case 776:
                x[i] ^= 3353;
                break;
            case 777:
                x[i] ^= 1024;
                break;
            case 778:
                x[i] ^= 1260;
                break;
            case 779:
                x[i] ^= 2495;
                break;
            case 780:
                x[i] ^= 1871;
                break;
            case 781:
                x[i] ^= 3044;
                break;
            case 782:
                x[i] ^= 2940;
                break;
            case 783:
                x[i] ^= 1729;
                break;
            case 784:
                x[i] ^= 1824;
                break;
            case 785:
                x[i] ^= 2510;
                break;
            case 786:
                x[i] ^= 1755;
                break;
            case 787:
                x[i] ^= 3926;
                break;
            case 788:
                x[i] ^= 2876;
                break;
            case 789:
                x[i] ^= 1449;
                break;
            case 790:
                x[i] ^= 2526;
                break;
            case 791:
                x[i] ^= 2923;
                break;
            case 792:
                x[i] ^= 559;
                break;
            case 793:
                x[i] ^= 622;
                break;
            case 794:
                x[i] ^= 198;
                break;
            case 795:
                x[i] ^= 3292;
                break;
            case 796:
                x[i] ^= 320;
                break;
            case 797:
                x[i] ^= 2571;
                break;
            case 798:
                x[i] ^= 1663;
                break;
            case 799:
                x[i] ^= 2556;
                break;
            case 800:
                x[i] ^= 1753;
                break;
            case 801:
                x[i] ^= 2906;
                break;
            case 802:
                x[i] ^= 2900;
                break;
            case 803:
                x[i] ^= 544;
                break;
            case 804:
                x[i] ^= 638;
                break;
            case 805:
                x[i] ^= 2004;
                break;
            case 806:
                x[i] ^= 2413;
                break;
            case 807:
                x[i] ^= 13;
                break;
            case 808:
                x[i] ^= 2345;
                break;
            case 809:
                x[i] ^= 280;
                break;
            case 810:
                x[i] ^= 376;
                break;
            case 811:
                x[i] ^= 746;
                break;
            case 812:
                x[i] ^= 485;
                break;
            case 813:
                x[i] ^= 393;
                break;
            case 814:
                x[i] ^= 3317;
                break;
            case 815:
                x[i] ^= 975;
                break;
            case 816:
                x[i] ^= 437;
                break;
            case 817:
                x[i] ^= 4044;
                break;
            case 818:
                x[i] ^= 270;
                break;
            case 819:
                x[i] ^= 4067;
                break;
            case 820:
                x[i] ^= 3457;
                break;
            case 821:
                x[i] ^= 2648;
                break;
            case 822:
                x[i] ^= 1865;
                break;
            case 823:
                x[i] ^= 3450;
                break;
            case 824:
                x[i] ^= 2984;
                break;
            case 825:
                x[i] ^= 4064;
                break;
            case 826:
                x[i] ^= 1134;
                break;
            case 827:
                x[i] ^= 2947;
                break;
            case 828:
                x[i] ^= 344;
                break;
            case 829:
                x[i] ^= 3720;
                break;
            case 830:
                x[i] ^= 3713;
                break;
            case 831:
                x[i] ^= 1039;
                break;
            case 832:
                x[i] ^= 3357;
                break;
            case 833:
                x[i] ^= 870;
                break;
            case 834:
                x[i] ^= 2265;
                break;
            case 835:
                x[i] ^= 2854;
                break;
            case 836:
                x[i] ^= 2574;
                break;
            case 837:
                x[i] ^= 3045;
                break;
            case 838:
                x[i] ^= 1579;
                break;
            case 839:
                x[i] ^= 530;
                break;
            case 840:
                x[i] ^= 3430;
                break;
            case 841:
                x[i] ^= 1430;
                break;
            case 842:
                x[i] ^= 3718;
                break;
            case 843:
                x[i] ^= 2367;
                break;
            case 844:
                x[i] ^= 602;
                break;
            case 845:
                x[i] ^= 919;
                break;
            case 846:
                x[i] ^= 575;
                break;
            case 847:
                x[i] ^= 2281;
                break;
            case 848:
                x[i] ^= 835;
                break;
            case 849:
                x[i] ^= 3906;
                break;
            case 850:
                x[i] ^= 773;
                break;
            case 851:
                x[i] ^= 3278;
                break;
            case 852:
                x[i] ^= 3499;
                break;
            case 853:
                x[i] ^= 1196;
                break;
            case 854:
                x[i] ^= 3204;
                break;
            case 855:
                x[i] ^= 1773;
                break;
            case 856:
                x[i] ^= 1390;
                break;
            case 857:
                x[i] ^= 2572;
                break;
            case 858:
                x[i] ^= 971;
                break;
            case 859:
                x[i] ^= 2202;
                break;
            case 860:
                x[i] ^= 4080;
                break;
            case 861:
                x[i] ^= 2768;
                break;
            case 862:
                x[i] ^= 2928;
                break;
            case 863:
                x[i] ^= 3809;
                break;
            case 864:
                x[i] ^= 3681;
                break;
            case 865:
                x[i] ^= 3103;
                break;
            case 866:
                x[i] ^= 3976;
                break;
            case 867:
                x[i] ^= 564;
                break;
            case 868:
                x[i] ^= 3520;
                break;
            case 869:
                x[i] ^= 3748;
                break;
            case 870:
                x[i] ^= 1658;
                break;
            case 871:
                x[i] ^= 2827;
                break;
            case 872:
                x[i] ^= 3879;
                break;
            case 873:
                x[i] ^= 3598;
                break;
            case 874:
                x[i] ^= 2338;
                break;
            case 875:
                x[i] ^= 1275;
                break;
            case 876:
                x[i] ^= 3476;
                break;
            case 877:
                x[i] ^= 1550;
                break;
            case 878:
                x[i] ^= 24;
                break;
            case 879:
                x[i] ^= 1547;
                break;
            case 880:
                x[i] ^= 1040;
                break;
            case 881:
                x[i] ^= 2225;
                break;
            case 882:
                x[i] ^= 1220;
                break;
            case 883:
                x[i] ^= 521;
                break;
            case 884:
                x[i] ^= 1604;
                break;
            case 885:
                x[i] ^= 1459;
                break;
            case 886:
                x[i] ^= 1360;
                break;
            case 887:
                x[i] ^= 264;
                break;
            case 888:
                x[i] ^= 4069;
                break;
            case 889:
                x[i] ^= 2068;
                break;
            case 890:
                x[i] ^= 3316;
                break;
            case 891:
                x[i] ^= 1958;
                break;
            case 892:
                x[i] ^= 1870;
                break;
            case 893:
                x[i] ^= 2540;
                break;
            case 894:
                x[i] ^= 1300;
                break;
            case 895:
                x[i] ^= 1959;
                break;
            case 896:
                x[i] ^= 261;
                break;
            case 897:
                x[i] ^= 387;
                break;
            case 898:
                x[i] ^= 941;
                break;
            case 899:
                x[i] ^= 2480;
                break;
            case 900:
                x[i] ^= 3657;
                break;
            case 901:
                x[i] ^= 2193;
                break;
            case 902:
                x[i] ^= 80;
                break;
            case 903:
                x[i] ^= 227;
                break;
            case 904:
                x[i] ^= 2741;
                break;
            case 905:
                x[i] ^= 1814;
                break;
            case 906:
                x[i] ^= 3479;
                break;
            case 907:
                x[i] ^= 486;
                break;
            case 908:
                x[i] ^= 3721;
                break;
            case 909:
                x[i] ^= 1781;
                break;
            case 910:
                x[i] ^= 2664;
                break;
            case 911:
                x[i] ^= 2360;
                break;
            case 912:
                x[i] ^= 767;
                break;
            case 913:
                x[i] ^= 1625;
                break;
            case 914:
                x[i] ^= 3512;
                break;
            case 915:
                x[i] ^= 1944;
                break;
            case 916:
                x[i] ^= 436;
                break;
            case 917:
                x[i] ^= 3153;
                break;
            case 918:
                x[i] ^= 3968;
                break;
            case 919:
                x[i] ^= 3990;
                break;
            case 920:
                x[i] ^= 2097;
                break;
            case 921:
                x[i] ^= 2869;
                break;
            case 922:
                x[i] ^= 3446;
                break;
            case 923:
                x[i] ^= 1365;
                break;
            case 924:
                x[i] ^= 3719;
                break;
            case 925:
                x[i] ^= 1585;
                break;
            case 926:
                x[i] ^= 845;
                break;
            case 927:
                x[i] ^= 994;
                break;
            case 928:
                x[i] ^= 306;
                break;
            case 929:
                x[i] ^= 2653;
                break;
            case 930:
                x[i] ^= 2599;
                break;
            case 931:
                x[i] ^= 548;
                break;
            case 932:
                x[i] ^= 2554;
                break;
            case 933:
                x[i] ^= 640;
                break;
            case 934:
                x[i] ^= 3179;
                break;
            case 935:
                x[i] ^= 627;
                break;
            case 936:
                x[i] ^= 2362;
                break;
            case 937:
                x[i] ^= 2243;
                break;
            case 938:
                x[i] ^= 720;
                break;
            case 939:
                x[i] ^= 1408;
                break;
            case 940:
                x[i] ^= 4035;
                break;
            case 941:
                x[i] ^= 960;
                break;
            case 942:
                x[i] ^= 1227;
                break;
            case 943:
                x[i] ^= 1948;
                break;
            case 944:
                x[i] ^= 279;
                break;
            case 945:
                x[i] ^= 3545;
                break;
            case 946:
                x[i] ^= 1752;
                break;
            case 947:
                x[i] ^= 2784;
                break;
            case 948:
                x[i] ^= 2014;
                break;
            case 949:
                x[i] ^= 2535;
                break;
            case 950:
                x[i] ^= 865;
                break;
            case 951:
                x[i] ^= 2879;
                break;
            case 952:
                x[i] ^= 3593;
                break;
            case 953:
                x[i] ^= 1222;
                break;
            case 954:
                x[i] ^= 3009;
                break;
            case 955:
                x[i] ^= 3155;
                break;
            case 956:
                x[i] ^= 3216;
                break;
            case 957:
                x[i] ^= 1929;
                break;
            case 958:
                x[i] ^= 1018;
                break;
            case 959:
                x[i] ^= 333;
                break;
            case 960:
                x[i] ^= 1063;
                break;
            case 961:
                x[i] ^= 1451;
                break;
            case 962:
                x[i] ^= 1923;
                break;
            case 963:
                x[i] ^= 1521;
                break;
            case 964:
                x[i] ^= 978;
                break;
            case 965:
                x[i] ^= 3983;
                break;
            case 966:
                x[i] ^= 3513;
                break;
            case 967:
                x[i] ^= 645;
                break;
            case 968:
                x[i] ^= 3937;
                break;
            case 969:
                x[i] ^= 2499;
                break;
            case 970:
                x[i] ^= 2934;
                break;
            case 971:
                x[i] ^= 3190;
                break;
            case 972:
                x[i] ^= 1747;
                break;
            case 973:
                x[i] ^= 2801;
                break;
            case 974:
                x[i] ^= 3741;
                break;
            case 975:
                x[i] ^= 1318;
                break;
            case 976:
                x[i] ^= 4052;
                break;
            case 977:
                x[i] ^= 2995;
                break;
            case 978:
                x[i] ^= 557;
                break;
            case 979:
                x[i] ^= 3859;
                break;
            case 980:
                x[i] ^= 1928;
                break;
            case 981:
                x[i] ^= 879;
                break;
            case 982:
                x[i] ^= 3389;
                break;
            case 983:
                x[i] ^= 3224;
                break;
            case 984:
                x[i] ^= 546;
                break;
            case 985:
                x[i] ^= 2503;
                break;
            case 986:
                x[i] ^= 1107;
                break;
            case 987:
                x[i] ^= 2506;
                break;
            case 988:
                x[i] ^= 770;
                break;
            case 989:
                x[i] ^= 3401;
                break;
            case 990:
                x[i] ^= 577;
                break;
            case 991:
                x[i] ^= 220;
                break;
            case 992:
                x[i] ^= 3533;
                break;
            case 993:
                x[i] ^= 2339;
                break;
            case 994:
                x[i] ^= 2769;
                break;
            case 995:
                x[i] ^= 499;
                break;
            case 996:
                x[i] ^= 187;
                break;
            case 997:
                x[i] ^= 1088;
                break;
            case 998:
                x[i] ^= 1927;
                break;
            case 999:
                x[i] ^= 3365;
                break;
            case 1000:
                x[i] ^= 421;
                break;
            case 1001:
                x[i] ^= 3147;
                break;
            case 1002:
                x[i] ^= 1421;
                break;
            case 1003:
                x[i] ^= 2738;
                break;
            case 1004:
                x[i] ^= 3217;
                break;
            case 1005:
                x[i] ^= 1350;
                break;
            case 1006:
                x[i] ^= 1893;
                break;
            case 1007:
                x[i] ^= 2010;
                break;
            case 1008:
                x[i] ^= 3170;
                break;
            case 1009:
                x[i] ^= 63;
                break;
            case 1010:
                x[i] ^= 2593;
                break;
            case 1011:
                x[i] ^= 2263;
                break;
            case 1012:
                x[i] ^= 2005;
                break;
            case 1013:
                x[i] ^= 1497;
                break;
            case 1014:
                x[i] ^= 1960;
                break;
            case 1015:
                x[i] ^= 2232;
                break;
            case 1016:
                x[i] ^= 657;
                break;
            case 1017:
                x[i] ^= 817;
                break;
            case 1018:
                x[i] ^= 2766;
                break;
            case 1019:
                x[i] ^= 597;
                break;
            case 1020:
                x[i] ^= 731;
                break;
            case 1021:
                x[i] ^= 878;
                break;
            case 1022:
                x[i] ^= 1232;
                break;
            case 1023:
                x[i] ^= 3307;
                break;
            case 1024:
                x[i] ^= 3902;
                break;
            case 1025:
                x[i] ^= 734;
                break;
            case 1026:
                x[i] ^= 2936;
                break;
            case 1027:
                x[i] ^= 491;
                break;
            case 1028:
                x[i] ^= 1358;
                break;
            case 1029:
                x[i] ^= 2674;
                break;
            case 1030:
                x[i] ^= 1427;
                break;
            case 1031:
                x[i] ^= 137;
                break;
            case 1032:
                x[i] ^= 2759;
                break;
            case 1033:
                x[i] ^= 2181;
                break;
            case 1034:
                x[i] ^= 4074;
                break;
            case 1035:
                x[i] ^= 927;
                break;
            case 1036:
                x[i] ^= 2926;
                break;
            case 1037:
                x[i] ^= 1155;
                break;
            case 1038:
                x[i] ^= 3707;
                break;
            case 1039:
                x[i] ^= 1575;
                break;
            case 1040:
                x[i] ^= 3313;
                break;
            case 1041:
                x[i] ^= 3409;
                break;
            case 1042:
                x[i] ^= 1188;
                break;
            case 1043:
                x[i] ^= 3736;
                break;
            case 1044:
                x[i] ^= 439;
                break;
            case 1045:
                x[i] ^= 1515;
                break;
            case 1046:
                x[i] ^= 501;
                break;
            case 1047:
                x[i] ^= 652;
                break;
            case 1048:
                x[i] ^= 2592;
                break;
            case 1049:
                x[i] ^= 2082;
                break;
            case 1050:
                x[i] ^= 1447;
                break;
            case 1051:
                x[i] ^= 798;
                break;
            case 1052:
                x[i] ^= 2886;
                break;
            case 1053:
                x[i] ^= 2868;
                break;
            case 1054:
                x[i] ^= 293;
                break;
            case 1055:
                x[i] ^= 3115;
                break;
            case 1056:
                x[i] ^= 1565;
                break;
            case 1057:
                x[i] ^= 2320;
                break;
            case 1058:
                x[i] ^= 795;
                break;
            case 1059:
                x[i] ^= 1487;
                break;
            case 1060:
                x[i] ^= 1445;
                break;
            case 1061:
                x[i] ^= 1848;
                break;
            case 1062:
                x[i] ^= 574;
                break;
            case 1063:
                x[i] ^= 2190;
                break;
            case 1064:
                x[i] ^= 1543;
                break;
            case 1065:
                x[i] ^= 166;
                break;
            case 1066:
                x[i] ^= 3812;
                break;
            case 1067:
                x[i] ^= 2471;
                break;
            case 1068:
                x[i] ^= 1115;
                break;
            case 1069:
                x[i] ^= 1239;
                break;
            case 1070:
                x[i] ^= 3891;
                break;
            case 1071:
                x[i] ^= 11;
                break;
            case 1072:
                x[i] ^= 3355;
                break;
            case 1073:
                x[i] ^= 3068;
                break;
            case 1074:
                x[i] ^= 1791;
                break;
            case 1075:
                x[i] ^= 624;
                break;
            case 1076:
                x[i] ^= 3932;
                break;
            case 1077:
                x[i] ^= 3664;
                break;
            case 1078:
                x[i] ^= 110;
                break;
            case 1079:
                x[i] ^= 1589;
                break;
            case 1080:
                x[i] ^= 2258;
                break;
            case 1081:
                x[i] ^= 2972;
                break;
            case 1082:
                x[i] ^= 2818;
                break;
            case 1083:
                x[i] ^= 2287;
                break;
            case 1084:
                x[i] ^= 1212;
                break;
            case 1085:
                x[i] ^= 525;
                break;
            case 1086:
                x[i] ^= 1183;
                break;
            case 1087:
                x[i] ^= 2418;
                break;
            case 1088:
                x[i] ^= 1114;
                break;
            case 1089:
                x[i] ^= 3971;
                break;
            case 1090:
                x[i] ^= 1106;
                break;
            case 1091:
                x[i] ^= 1273;
                break;
            case 1092:
                x[i] ^= 1283;
                break;
            case 1093:
                x[i] ^= 318;
                break;
            case 1094:
                x[i] ^= 4063;
                break;
            case 1095:
                x[i] ^= 2559;
                break;
            case 1096:
                x[i] ^= 3165;
                break;
            case 1097:
                x[i] ^= 2091;
                break;
            case 1098:
                x[i] ^= 3291;
                break;
            case 1099:
                x[i] ^= 4030;
                break;
            case 1100:
                x[i] ^= 1993;
                break;
            case 1101:
                x[i] ^= 3772;
                break;
            case 1102:
                x[i] ^= 1607;
                break;
            case 1103:
                x[i] ^= 3261;
                break;
            case 1104:
                x[i] ^= 567;
                break;
            case 1105:
                x[i] ^= 517;
                break;
            case 1106:
                x[i] ^= 1522;
                break;
            case 1107:
                x[i] ^= 3917;
                break;
            case 1108:
                x[i] ^= 3024;
                break;
            case 1109:
                x[i] ^= 1290;
                break;
            case 1110:
                x[i] ^= 3622;
                break;
            case 1111:
                x[i] ^= 3778;
                break;
            case 1112:
                x[i] ^= 3050;
                break;
            case 1113:
                x[i] ^= 1763;
                break;
            case 1114:
                x[i] ^= 3014;
                break;
            case 1115:
                x[i] ^= 3677;
                break;
            case 1116:
                x[i] ^= 1259;
                break;
            case 1117:
                x[i] ^= 3419;
                break;
            case 1118:
                x[i] ^= 2111;
                break;
            case 1119:
                x[i] ^= 1654;
                break;
            case 1120:
                x[i] ^= 1393;
                break;
            case 1121:
                x[i] ^= 2371;
                break;
            case 1122:
                x[i] ^= 3413;
                break;
            case 1123:
                x[i] ^= 1108;
                break;
            case 1124:
                x[i] ^= 2515;
                break;
            case 1125:
                x[i] ^= 3627;
                break;
            case 1126:
                x[i] ^= 3124;
                break;
            case 1127:
                x[i] ^= 1037;
                break;
            case 1128:
                x[i] ^= 2789;
                break;
            case 1129:
                x[i] ^= 3031;
                break;
            case 1130:
                x[i] ^= 3189;
                break;
            case 1131:
                x[i] ^= 348;
                break;
            case 1132:
                x[i] ^= 2658;
                break;
            case 1133:
                x[i] ^= 882;
                break;
            case 1134:
                x[i] ^= 708;
                break;
            case 1135:
                x[i] ^= 922;
                break;
            case 1136:
                x[i] ^= 1555;
                break;
            case 1137:
                x[i] ^= 255;
                break;
            case 1138:
                x[i] ^= 2866;
                break;
            case 1139:
                x[i] ^= 3540;
                break;
            case 1140:
                x[i] ^= 3018;
                break;
            case 1141:
                x[i] ^= 2979;
                break;
            case 1142:
                x[i] ^= 2823;
                break;
            case 1143:
                x[i] ^= 1071;
                break;
            case 1144:
                x[i] ^= 2317;
                break;
            case 1145:
                x[i] ^= 2783;
                break;
            case 1146:
                x[i] ^= 3984;
                break;
            case 1147:
                x[i] ^= 1157;
                break;
            case 1148:
                x[i] ^= 1653;
                break;
            case 1149:
                x[i] ^= 620;
                break;
            case 1150:
                x[i] ^= 397;
                break;
            case 1151:
                x[i] ^= 821;
                break;
            case 1152:
                x[i] ^= 2686;
                break;
            case 1153:
                x[i] ^= 1384;
                break;
            case 1154:
                x[i] ^= 2951;
                break;
            case 1155:
                x[i] ^= 2705;
                break;
            case 1156:
                x[i] ^= 3881;
                break;
            case 1157:
                x[i] ^= 999;
                break;
            case 1158:
                x[i] ^= 1248;
                break;
            case 1159:
                x[i] ^= 3289;
                break;
            case 1160:
                x[i] ^= 3402;
                break;
            case 1161:
                x[i] ^= 2600;
                break;
            case 1162:
                x[i] ^= 1669;
                break;
            case 1163:
                x[i] ^= 3846;
                break;
            case 1164:
                x[i] ^= 875;
                break;
            case 1165:
                x[i] ^= 3951;
                break;
            case 1166:
                x[i] ^= 3849;
                break;
            case 1167:
                x[i] ^= 375;
                break;
            case 1168:
                x[i] ^= 2197;
                break;
            case 1169:
                x[i] ^= 3197;
                break;
            case 1170:
                x[i] ^= 2893;
                break;
            case 1171:
                x[i] ^= 1493;
                break;
            case 1172:
                x[i] ^= 225;
                break;
            case 1173:
                x[i] ^= 2017;
                break;
            case 1174:
                x[i] ^= 1996;
                break;
            case 1175:
                x[i] ^= 2173;
                break;
            case 1176:
                x[i] ^= 186;
                break;
            case 1177:
                x[i] ^= 2999;
                break;
            case 1178:
                x[i] ^= 3079;
                break;
            case 1179:
                x[i] ^= 3947;
                break;
            case 1180:
                x[i] ^= 2222;
                break;
            case 1181:
                x[i] ^= 3798;
                break;
            case 1182:
                x[i] ^= 1288;
                break;
            case 1183:
                x[i] ^= 1201;
                break;
            case 1184:
                x[i] ^= 86;
                break;
            case 1185:
                x[i] ^= 3803;
                break;
            case 1186:
                x[i] ^= 2527;
                break;
            case 1187:
                x[i] ^= 1938;
                break;
            case 1188:
                x[i] ^= 2138;
                break;
            case 1189:
                x[i] ^= 204;
                break;
            case 1190:
                x[i] ^= 340;
                break;
            case 1191:
                x[i] ^= 2187;
                break;
            case 1192:
                x[i] ^= 480;
                break;
            case 1193:
                x[i] ^= 3602;
                break;
            case 1194:
                x[i] ^= 1936;
                break;
            case 1195:
                x[i] ^= 52;
                break;
            case 1196:
                x[i] ^= 3196;
                break;
            case 1197:
                x[i] ^= 384;
                break;
            case 1198:
                x[i] ^= 1925;
                break;
            case 1199:
                x[i] ^= 2518;
                break;
            case 1200:
                x[i] ^= 1333;
                break;
            case 1201:
                x[i] ^= 3840;
                break;
            case 1202:
                x[i] ^= 629;
                break;
            case 1203:
                x[i] ^= 215;
                break;
            case 1204:
                x[i] ^= 880;
                break;
            case 1205:
                x[i] ^= 2717;
                break;
            case 1206:
                x[i] ^= 917;
                break;
            case 1207:
                x[i] ^= 3531;
                break;
            case 1208:
                x[i] ^= 3269;
                break;
            case 1209:
                x[i] ^= 3725;
                break;
            case 1210:
                x[i] ^= 1346;
                break;
            case 1211:
                x[i] ^= 604;
                break;
            case 1212:
                x[i] ^= 1897;
                break;
            case 1213:
                x[i] ^= 2644;
                break;
            case 1214:
                x[i] ^= 3097;
                break;
            case 1215:
                x[i] ^= 1937;
                break;
            case 1216:
                x[i] ^= 1492;
                break;
            case 1217:
                x[i] ^= 352;
                break;
            case 1218:
                x[i] ^= 2403;
                break;
            case 1219:
                x[i] ^= 405;
                break;
            case 1220:
                x[i] ^= 3665;
                break;
            case 1221:
                x[i] ^= 1533;
                break;
            case 1222:
                x[i] ^= 2819;
                break;
            case 1223:
                x[i] ^= 3553;
                break;
            case 1224:
                x[i] ^= 1611;
                break;
            case 1225:
                x[i] ^= 1914;
                break;
            case 1226:
                x[i] ^= 2655;
                break;
            case 1227:
                x[i] ^= 814;
                break;
            case 1228:
                x[i] ^= 3339;
                break;
            case 1229:
                x[i] ^= 2247;
                break;
            case 1230:
                x[i] ^= 2525;
                break;
            case 1231:
                x[i] ^= 3466;
                break;
            case 1232:
                x[i] ^= 1863;
                break;
            case 1233:
                x[i] ^= 669;
                break;
            case 1234:
                x[i] ^= 515;
                break;
            case 1235:
                x[i] ^= 2095;
                break;
            case 1236:
                x[i] ^= 3767;
                break;
            case 1237:
                x[i] ^= 3584;
                break;
            case 1238:
                x[i] ^= 1709;
                break;
            case 1239:
                x[i] ^= 3166;
                break;
            case 1240:
                x[i] ^= 715;
                break;
            case 1241:
                x[i] ^= 2850;
                break;
            case 1242:
                x[i] ^= 1819;
                break;
            case 1243:
                x[i] ^= 2736;
                break;
            case 1244:
                x[i] ^= 1006;
                break;
            case 1245:
                x[i] ^= 3575;
                break;
            case 1246:
                x[i] ^= 1159;
                break;
            case 1247:
                x[i] ^= 997;
                break;
            case 1248:
                x[i] ^= 3745;
                break;
            case 1249:
                x[i] ^= 252;
                break;
            case 1250:
                x[i] ^= 2983;
                break;
            case 1251:
                x[i] ^= 2466;
                break;
            case 1252:
                x[i] ^= 1799;
                break;
            case 1253:
                x[i] ^= 3061;
                break;
            case 1254:
                x[i] ^= 757;
                break;
            case 1255:
                x[i] ^= 1483;
                break;
            case 1256:
                x[i] ^= 3600;
                break;
            case 1257:
                x[i] ^= 165;
                break;
            case 1258:
                x[i] ^= 2773;
                break;
            case 1259:
                x[i] ^= 2815;
                break;
            case 1260:
                x[i] ^= 1452;
                break;
            case 1261:
                x[i] ^= 1602;
                break;
            case 1262:
                x[i] ^= 3448;
                break;
            case 1263:
                x[i] ^= 1671;
                break;
            case 1264:
                x[i] ^= 1626;
                break;
            case 1265:
                x[i] ^= 3169;
                break;
            case 1266:
                x[i] ^= 3814;
                break;
            case 1267:
                x[i] ^= 1411;
                break;
            case 1268:
                x[i] ^= 736;
                break;
            case 1269:
                x[i] ^= 2754;
                break;
            case 1270:
                x[i] ^= 3950;
                break;
            case 1271:
                x[i] ^= 49;
                break;
            case 1272:
                x[i] ^= 3732;
                break;
            case 1273:
                x[i] ^= 1972;
                break;
            case 1274:
                x[i] ^= 2907;
                break;
            case 1275:
                x[i] ^= 3370;
                break;
            case 1276:
                x[i] ^= 3784;
                break;
            case 1277:
                x[i] ^= 3960;
                break;
            case 1278:
                x[i] ^= 3150;
                break;
            case 1279:
                x[i] ^= 3168;
                break;
            case 1280:
                x[i] ^= 3481;
                break;
            case 1281:
                x[i] ^= 2974;
                break;
            case 1282:
                x[i] ^= 411;
                break;
            case 1283:
                x[i] ^= 291;
                break;
            case 1284:
                x[i] ^= 1627;
                break;
            case 1285:
                x[i] ^= 310;
                break;
            case 1286:
                x[i] ^= 830;
                break;
            case 1287:
                x[i] ^= 3811;
                break;
            case 1288:
                x[i] ^= 2354;
                break;
            case 1289:
                x[i] ^= 3232;
                break;
            case 1290:
                x[i] ^= 1903;
                break;
            case 1291:
                x[i] ^= 1966;
                break;
            case 1292:
                x[i] ^= 1998;
                break;
            case 1293:
                x[i] ^= 3795;
                break;
            case 1294:
                x[i] ^= 3996;
                break;
            case 1295:
                x[i] ^= 3667;
                break;
            case 1296:
                x[i] ^= 2651;
                break;
            case 1297:
                x[i] ^= 2849;
                break;
            case 1298:
                x[i] ^= 3143;
                break;
            case 1299:
                x[i] ^= 2701;
                break;
            case 1300:
                x[i] ^= 2153;
                break;
            case 1301:
                x[i] ^= 3898;
                break;
            case 1302:
                x[i] ^= 979;
                break;
            case 1303:
                x[i] ^= 383;
                break;
            case 1304:
                x[i] ^= 396;
                break;
            case 1305:
                x[i] ^= 2342;
                break;
            case 1306:
                x[i] ^= 1373;
                break;
            case 1307:
                x[i] ^= 2817;
                break;
            case 1308:
                x[i] ^= 2942;
                break;
            case 1309:
                x[i] ^= 2428;
                break;
            case 1310:
                x[i] ^= 435;
                break;
            case 1311:
                x[i] ^= 2751;
                break;
            case 1312:
                x[i] ^= 130;
                break;
            case 1313:
                x[i] ^= 1813;
                break;
            case 1314:
                x[i] ^= 2475;
                break;
            case 1315:
                x[i] ^= 735;
                break;
            case 1316:
                x[i] ^= 1730;
                break;
            case 1317:
                x[i] ^= 2605;
                break;
            case 1318:
                x[i] ^= 3899;
                break;
            case 1319:
                x[i] ^= 19;
                break;
            case 1320:
                x[i] ^= 1351;
                break;
            case 1321:
                x[i] ^= 2401;
                break;
            case 1322:
                x[i] ^= 1380;
                break;
            case 1323:
                x[i] ^= 2147;
                break;
            case 1324:
                x[i] ^= 3869;
                break;
            case 1325:
                x[i] ^= 796;
                break;
            case 1326:
                x[i] ^= 2504;
                break;
            case 1327:
                x[i] ^= 1054;
                break;
            case 1328:
                x[i] ^= 1489;
                break;
            case 1329:
                x[i] ^= 2752;
                break;
            case 1330:
                x[i] ^= 1571;
                break;
            case 1331:
                x[i] ^= 2707;
                break;
            case 1332:
                x[i] ^= 4020;
                break;
            case 1333:
                x[i] ^= 3378;
                break;
            case 1334:
                x[i] ^= 2241;
                break;
            case 1335:
                x[i] ^= 2786;
                break;
            case 1336:
                x[i] ^= 1949;
                break;
            case 1337:
                x[i] ^= 1009;
                break;
            case 1338:
                x[i] ^= 3934;
                break;
            case 1339:
                x[i] ^= 1714;
                break;
            case 1340:
                x[i] ^= 2447;
                break;
            case 1341:
                x[i] ^= 3931;
                break;
            case 1342:
                x[i] ^= 2027;
                break;
            case 1343:
                x[i] ^= 2455;
                break;
            case 1344:
                x[i] ^= 4027;
                break;
            case 1345:
                x[i] ^= 802;
                break;
            case 1346:
                x[i] ^= 2015;
                break;
            case 1347:
                x[i] ^= 807;
                break;
            case 1348:
                x[i] ^= 3017;
                break;
            case 1349:
                x[i] ^= 3228;
                break;
            case 1350:
                x[i] ^= 3886;
                break;
            case 1351:
                x[i] ^= 2863;
                break;
            case 1352:
                x[i] ^= 3308;
                break;
            case 1353:
                x[i] ^= 3781;
                break;
            case 1354:
                x[i] ^= 792;
                break;
            case 1355:
                x[i] ^= 1945;
                break;
            case 1356:
                x[i] ^= 2985;
                break;
            case 1357:
                x[i] ^= 314;
                break;
            case 1358:
                x[i] ^= 836;
                break;
            case 1359:
                x[i] ^= 265;
                break;
            case 1360:
                x[i] ^= 1242;
                break;
            case 1361:
                x[i] ^= 806;
                break;
            case 1362:
                x[i] ^= 680;
                break;
            case 1363:
                x[i] ^= 2677;
                break;
            case 1364:
                x[i] ^= 454;
                break;
            case 1365:
                x[i] ^= 143;
                break;
            case 1366:
                x[i] ^= 3783;
                break;
            case 1367:
                x[i] ^= 787;
                break;
            case 1368:
                x[i] ^= 1786;
                break;
            case 1369:
                x[i] ^= 730;
                break;
            case 1370:
                x[i] ^= 1138;
                break;
            case 1371:
                x[i] ^= 3827;
                break;
            case 1372:
                x[i] ^= 1268;
                break;
            case 1373:
                x[i] ^= 3963;
                break;
            case 1374:
                x[i] ^= 2407;
                break;
            case 1375:
                x[i] ^= 2406;
                break;
            case 1376:
                x[i] ^= 2669;
                break;
            case 1377:
                x[i] ^= 3302;
                break;
            case 1378:
                x[i] ^= 430;
                break;
            case 1379:
                x[i] ^= 1975;
                break;
            case 1380:
                x[i] ^= 2062;
                break;
            case 1381:
                x[i] ^= 832;
                break;
            case 1382:
                x[i] ^= 243;
                break;
            case 1383:
                x[i] ^= 2375;
                break;
            case 1384:
                x[i] ^= 1695;
                break;
            case 1385:
                x[i] ^= 3743;
                break;
            case 1386:
                x[i] ^= 1215;
                break;
            case 1387:
                x[i] ^= 801;
                break;
            case 1388:
                x[i] ^= 2898;
                break;
            case 1389:
                x[i] ^= 1228;
                break;
            case 1390:
                x[i] ^= 3112;
                break;
            case 1391:
                x[i] ^= 1221;
                break;
            case 1392:
                x[i] ^= 3201;
                break;
            case 1393:
                x[i] ^= 277;
                break;
            case 1394:
                x[i] ^= 214;
                break;
            case 1395:
                x[i] ^= 759;
                break;
            case 1396:
                x[i] ^= 2386;
                break;
            case 1397:
                x[i] ^= 2780;
                break;
            case 1398:
                x[i] ^= 992;
                break;
            case 1399:
                x[i] ^= 3791;
                break;
            case 1400:
                x[i] ^= 871;
                break;
            case 1401:
                x[i] ^= 1034;
                break;
            case 1402:
                x[i] ^= 2770;
                break;
            case 1403:
                x[i] ^= 3771;
                break;
            case 1404:
                x[i] ^= 1517;
                break;
            case 1405:
                x[i] ^= 995;
                break;
            case 1406:
                x[i] ^= 1540;
                break;
            case 1407:
                x[i] ^= 1886;
                break;
            case 1408:
                x[i] ^= 3081;
                break;
            case 1409:
                x[i] ^= 2891;
                break;
            case 1410:
                x[i] ^= 3841;
                break;
            case 1411:
                x[i] ^= 452;
                break;
            case 1412:
                x[i] ^= 4085;
                break;
            case 1413:
                x[i] ^= 1644;
                break;
            case 1414:
                x[i] ^= 2040;
                break;
            case 1415:
                x[i] ^= 3113;
                break;
            case 1416:
                x[i] ^= 3085;
                break;
            case 1417:
                x[i] ^= 3687;
                break;
            case 1418:
                x[i] ^= 2685;
                break;
            case 1419:
                x[i] ^= 2825;
                break;
            case 1420:
                x[i] ^= 1809;
                break;
            case 1421:
                x[i] ^= 3172;
                break;
            case 1422:
                x[i] ^= 3558;
                break;
            case 1423:
                x[i] ^= 260;
                break;
            case 1424:
                x[i] ^= 1987;
                break;
            case 1425:
                x[i] ^= 1887;
                break;
            case 1426:
                x[i] ^= 2132;
                break;
            case 1427:
                x[i] ^= 3094;
                break;
            case 1428:
                x[i] ^= 3088;
                break;
            case 1429:
                x[i] ^= 73;
                break;
            case 1430:
                x[i] ^= 3787;
                break;
            case 1431:
                x[i] ^= 2318;
                break;
            case 1432:
                x[i] ^= 2434;
                break;
            case 1433:
                x[i] ^= 2611;
                break;
            case 1434:
                x[i] ^= 4076;
                break;
            case 1435:
                x[i] ^= 2450;
                break;
            case 1436:
                x[i] ^= 3592;
                break;
            case 1437:
                x[i] ^= 683;
                break;
            case 1438:
                x[i] ^= 1816;
                break;
            case 1439:
                x[i] ^= 362;
                break;
            case 1440:
                x[i] ^= 2234;
                break;
            case 1441:
                x[i] ^= 611;
                break;
            case 1442:
                x[i] ^= 2373;
                break;
            case 1443:
                x[i] ^= 2451;
                break;
            case 1444:
                x[i] ^= 2656;
                break;
            case 1445:
                x[i] ^= 3563;
                break;
            case 1446:
                x[i] ^= 3503;
                break;
            case 1447:
                x[i] ^= 3005;
                break;
            case 1448:
                x[i] ^= 1726;
                break;
            case 1449:
                x[i] ^= 639;
                break;
            case 1450:
                x[i] ^= 1440;
                break;
            case 1451:
                x[i] ^= 2968;
                break;
            case 1452:
                x[i] ^= 4018;
                break;
            case 1453:
                x[i] ^= 8;
                break;
            case 1454:
                x[i] ^= 3361;
                break;
            case 1455:
                x[i] ^= 3157;
                break;
            case 1456:
                x[i] ^= 3949;
                break;
            case 1457:
                x[i] ^= 1153;
                break;
            case 1458:
                x[i] ^= 409;
                break;
            case 1459:
                x[i] ^= 1530;
                break;
            case 1460:
                x[i] ^= 56;
                break;
            case 1461:
                x[i] ^= 3850;
                break;
            case 1462:
                x[i] ^= 3310;
                break;
            case 1463:
                x[i] ^= 1935;
                break;
            case 1464:
                x[i] ^= 1485;
                break;
            case 1465:
                x[i] ^= 2212;
                break;
            case 1466:
                x[i] ^= 2158;
                break;
            case 1467:
                x[i] ^= 2139;
                break;
            case 1468:
                x[i] ^= 2614;
                break;
            case 1469:
                x[i] ^= 2946;
                break;
            case 1470:
                x[i] ^= 1563;
                break;
            case 1471:
                x[i] ^= 3892;
                break;
            case 1472:
                x[i] ^= 918;
                break;
            case 1473:
                x[i] ^= 2029;
                break;
            case 1474:
                x[i] ^= 1724;
                break;
            case 1475:
                x[i] ^= 1289;
                break;
            case 1476:
                x[i] ^= 1834;
                break;
            case 1477:
                x[i] ^= 4066;
                break;
            case 1478:
                x[i] ^= 2221;
                break;
            case 1479:
                x[i] ^= 1021;
                break;
            case 1480:
                x[i] ^= 1964;
                break;
            case 1481:
                x[i] ^= 136;
                break;
            case 1482:
                x[i] ^= 3794;
                break;
            case 1483:
                x[i] ^= 1839;
                break;
            case 1484:
                x[i] ^= 1690;
                break;
            case 1485:
                x[i] ^= 26;
                break;
            case 1486:
                x[i] ^= 1986;
                break;
            case 1487:
                x[i] ^= 156;
                break;
            case 1488:
                x[i] ^= 2541;
                break;
            case 1489:
                x[i] ^= 3252;
                break;
            case 1490:
                x[i] ^= 3586;
                break;
            case 1491:
                x[i] ^= 741;
                break;
            case 1492:
                x[i] ^= 4090;
                break;
            case 1493:
                x[i] ^= 3208;
                break;
            case 1494:
                x[i] ^= 1061;
                break;
            case 1495:
                x[i] ^= 3706;
                break;
            case 1496:
                x[i] ^= 3498;
                break;
            case 1497:
                x[i] ^= 2124;
                break;
            case 1498:
                x[i] ^= 3388;
                break;
            case 1499:
                x[i] ^= 2439;
                break;
            case 1500:
                x[i] ^= 909;
                break;
            case 1501:
                x[i] ^= 2125;
                break;
            case 1502:
                x[i] ^= 2792;
                break;
            case 1503:
                x[i] ^= 2618;
                break;
            case 1504:
                x[i] ^= 133;
                break;
            case 1505:
                x[i] ^= 674;
                break;
            case 1506:
                x[i] ^= 1224;
                break;
            case 1507:
                x[i] ^= 3417;
                break;
            case 1508:
                x[i] ^= 1976;
                break;
            case 1509:
                x[i] ^= 1169;
                break;
            case 1510:
                x[i] ^= 939;
                break;
            case 1511:
                x[i] ^= 1223;
                break;
            case 1512:
                x[i] ^= 3075;
                break;
            case 1513:
                x[i] ^= 2649;
                break;
            case 1514:
                x[i] ^= 490;
                break;
            case 1515:
                x[i] ^= 1549;
                break;
            case 1516:
                x[i] ^= 1324;
                break;
            case 1517:
                x[i] ^= 599;
                break;
            case 1518:
                x[i] ^= 3538;
                break;
            case 1519:
                x[i] ^= 2731;
                break;
            case 1520:
                x[i] ^= 3845;
                break;
            case 1521:
                x[i] ^= 3141;
                break;
            case 1522:
                x[i] ^= 3314;
                break;
            case 1523:
                x[i] ^= 711;
                break;
            case 1524:
                x[i] ^= 2253;
                break;
            case 1525:
                x[i] ^= 610;
                break;
            case 1526:
                x[i] ^= 3042;
                break;
            case 1527:
                x[i] ^= 2683;
                break;
            case 1528:
                x[i] ^= 3651;
                break;
            case 1529:
                x[i] ^= 1932;
                break;
            case 1530:
                x[i] ^= 3464;
                break;
            case 1531:
                x[i] ^= 957;
                break;
            case 1532:
                x[i] ^= 970;
                break;
            case 1533:
                x[i] ^= 1150;
                break;
            case 1534:
                x[i] ^= 996;
                break;
            case 1535:
                x[i] ^= 10;
                break;
            case 1536:
                x[i] ^= 2816;
                break;
            case 1537:
                x[i] ^= 1133;
                break;
            case 1538:
                x[i] ^= 2698;
                break;
            case 1539:
                x[i] ^= 596;
                break;
            case 1540:
                x[i] ^= 3003;
                break;
            case 1541:
                x[i] ^= 3277;
                break;
            case 1542:
                x[i] ^= 484;
                break;
            case 1543:
                x[i] ^= 2915;
                break;
            case 1544:
                x[i] ^= 3570;
                break;
            case 1545:
                x[i] ^= 2821;
                break;
            case 1546:
                x[i] ^= 1917;
                break;
            case 1547:
                x[i] ^= 3324;
                break;
            case 1548:
                x[i] ^= 3372;
                break;
            case 1549:
                x[i] ^= 2524;
                break;
            case 1550:
                x[i] ^= 2119;
                break;
            case 1551:
                x[i] ^= 312;
                break;
            case 1552:
                x[i] ^= 2617;
                break;
            case 1553:
                x[i] ^= 3838;
                break;
            case 1554:
                x[i] ^= 1779;
                break;
            case 1555:
                x[i] ^= 1685;
                break;
            case 1556:
                x[i] ^= 948;
                break;
            case 1557:
                x[i] ^= 1050;
                break;
            case 1558:
                x[i] ^= 2313;
                break;
            case 1559:
                x[i] ^= 558;
                break;
            case 1560:
                x[i] ^= 1599;
                break;
            case 1561:
                x[i] ^= 750;
                break;
            case 1562:
                x[i] ^= 3268;
                break;
            case 1563:
                x[i] ^= 353;
                break;
            case 1564:
                x[i] ^= 2720;
                break;
            case 1565:
                x[i] ^= 2464;
                break;
            case 1566:
                x[i] ^= 3111;
                break;
            case 1567:
                x[i] ^= 2060;
                break;
            case 1568:
                x[i] ^= 1869;
                break;
            case 1569:
                x[i] ^= 3148;
                break;
            case 1570:
                x[i] ^= 3429;
                break;
            case 1571:
                x[i] ^= 2804;
                break;
            case 1572:
                x[i] ^= 406;
                break;
            case 1573:
                x[i] ^= 1640;
                break;
            case 1574:
                x[i] ^= 2765;
                break;
            case 1575:
                x[i] ^= 2235;
                break;
            case 1576:
                x[i] ^= 967;
                break;
            case 1577:
                x[i] ^= 2383;
                break;
            case 1578:
                x[i] ^= 2391;
                break;
            case 1579:
                x[i] ^= 3474;
                break;
            case 1580:
                x[i] ^= 2888;
                break;
            case 1581:
                x[i] ^= 827;
                break;
            case 1582:
                x[i] ^= 284;
                break;
            case 1583:
                x[i] ^= 4011;
                break;
            case 1584:
                x[i] ^= 3206;
                break;
            case 1585:
                x[i] ^= 472;
                break;
            case 1586:
                x[i] ^= 3480;
                break;
            case 1587:
                x[i] ^= 2198;
                break;
            case 1588:
                x[i] ^= 2586;
                break;
            case 1589:
                x[i] ^= 2637;
                break;
            case 1590:
                x[i] ^= 2230;
                break;
            case 1591:
                x[i] ^= 2462;
                break;
            case 1592:
                x[i] ^= 2404;
                break;
            case 1593:
                x[i] ^= 1851;
                break;
            case 1594:
                x[i] ^= 1924;
                break;
            case 1595:
                x[i] ^= 2370;
                break;
            case 1596:
                x[i] ^= 3432;
                break;
            case 1597:
                x[i] ^= 2051;
                break;
            case 1598:
                x[i] ^= 3813;
                break;
            case 1599:
                x[i] ^= 3351;
                break;
            case 1600:
                x[i] ^= 1894;
                break;
            case 1601:
                x[i] ^= 1586;
                break;
            case 1602:
                x[i] ^= 1735;
                break;
            case 1603:
                x[i] ^= 1991;
                break;
            case 1604:
                x[i] ^= 2841;
                break;
            case 1605:
                x[i] ^= 3070;
                break;
            case 1606:
                x[i] ^= 3670;
                break;
            case 1607:
                x[i] ^= 3639;
                break;
            case 1608:
                x[i] ^= 2058;
                break;
            case 1609:
                x[i] ^= 245;
                break;
            case 1610:
                x[i] ^= 122;
                break;
            case 1611:
                x[i] ^= 2146;
                break;
            case 1612:
                x[i] ^= 1909;
                break;
            case 1613:
                x[i] ^= 2465;
                break;
            case 1614:
                x[i] ^= 915;
                break;
            case 1615:
                x[i] ^= 2564;
                break;
            case 1616:
                x[i] ^= 2271;
                break;
            case 1617:
                x[i] ^= 2755;
                break;
            case 1618:
                x[i] ^= 77;
                break;
            case 1619:
                x[i] ^= 666;
                break;
            case 1620:
                x[i] ^= 1010;
                break;
            case 1621:
                x[i] ^= 1584;
                break;
            case 1622:
                x[i] ^= 1982;
                break;
            case 1623:
                x[i] ^= 1446;
                break;
            case 1624:
                x[i] ^= 2814;
                break;
            case 1625:
                x[i] ^= 1147;
                break;
            case 1626:
                x[i] ^= 51;
                break;
            case 1627:
                x[i] ^= 2834;
                break;
            case 1628:
                x[i] ^= 337;
                break;
            case 1629:
                x[i] ^= 1316;
                break;
            case 1630:
                x[i] ^= 1127;
                break;
            case 1631:
                x[i] ^= 3262;
                break;
            case 1632:
                x[i] ^= 789;
                break;
            case 1633:
                x[i] ^= 3890;
                break;
            case 1634:
                x[i] ^= 4060;
                break;
            case 1635:
                x[i] ^= 849;
                break;
            case 1636:
                x[i] ^= 2219;
                break;
            case 1637:
                x[i] ^= 2294;
                break;
            case 1638:
                x[i] ^= 1310;
                break;
            case 1639:
                x[i] ^= 3171;
                break;
            case 1640:
                x[i] ^= 2402;
                break;
            case 1641:
                x[i] ^= 2856;
                break;
            case 1642:
                x[i] ^= 606;
                break;
            case 1643:
                x[i] ^= 3436;
                break;
            case 1644:
                x[i] ^= 3060;
                break;
            case 1645:
                x[i] ^= 4062;
                break;
            case 1646:
                x[i] ^= 2175;
                break;
            case 1647:
                x[i] ^= 4075;
                break;
            case 1648:
                x[i] ^= 3251;
                break;
            case 1649:
                x[i] ^= 4034;
                break;
            case 1650:
                x[i] ^= 1916;
                break;
            case 1651:
                x[i] ^= 1906;
                break;
            case 1652:
                x[i] ^= 2437;
                break;
            case 1653:
                x[i] ^= 440;
                break;
            case 1654:
                x[i] ^= 1210;
                break;
            case 1655:
                x[i] ^= 98;
                break;
            case 1656:
                x[i] ^= 2425;
                break;
            case 1657:
                x[i] ^= 2207;
                break;
            case 1658:
                x[i] ^= 1105;
                break;
            case 1659:
                x[i] ^= 297;
                break;
            case 1660:
                x[i] ^= 619;
                break;
            case 1661:
                x[i] ^= 2668;
                break;
            case 1662:
                x[i] ^= 2633;
                break;
            case 1663:
                x[i] ^= 3418;
                break;
            case 1664:
                x[i] ^= 1593;
                break;
            case 1665:
                x[i] ^= 2711;
                break;
            case 1666:
                x[i] ^= 2250;
                break;
            case 1667:
                x[i] ^= 2925;
                break;
            case 1668:
                x[i] ^= 3254;
                break;
            case 1669:
                x[i] ^= 1126;
                break;
            case 1670:
                x[i] ^= 998;
                break;
            case 1671:
                x[i] ^= 3610;
                break;
            case 1672:
                x[i] ^= 272;
                break;
            case 1673:
                x[i] ^= 1263;
                break;
            case 1674:
                x[i] ^= 217;
                break;
            case 1675:
                x[i] ^= 1743;
                break;
            case 1676:
                x[i] ^= 4001;
                break;
            case 1677:
                x[i] ^= 3529;
                break;
            case 1678:
                x[i] ^= 1067;
                break;
            case 1679:
                x[i] ^= 471;
                break;
            case 1680:
                x[i] ^= 2350;
                break;
            case 1681:
                x[i] ^= 3632;
                break;
            case 1682:
                x[i] ^= 3345;
                break;
            case 1683:
                x[i] ^= 3130;
                break;
            case 1684:
                x[i] ^= 2415;
                break;
            case 1685:
                x[i] ^= 1647;
                break;
            case 1686:
                x[i] ^= 4072;
                break;
            case 1687:
                x[i] ^= 3556;
                break;
            case 1688:
                x[i] ^= 3997;
                break;
            case 1689:
                x[i] ^= 3517;
                break;
            case 1690:
                x[i] ^= 2591;
                break;
            case 1691:
                x[i] ^= 3403;
                break;
            case 1692:
                x[i] ^= 287;
                break;
            case 1693:
                x[i] ^= 1803;
                break;
            case 1694:
                x[i] ^= 2666;
                break;
            case 1695:
                x[i] ^= 464;
                break;
            case 1696:
                x[i] ^= 3445;
                break;
            case 1697:
                x[i] ^= 3921;
                break;
            case 1698:
                x[i] ^= 259;
                break;
            case 1699:
                x[i] ^= 2788;
                break;
            case 1700:
                x[i] ^= 316;
                break;
            case 1701:
                x[i] ^= 2183;
                break;
            case 1702:
                x[i] ^= 508;
                break;
            case 1703:
                x[i] ^= 1423;
                break;
            case 1704:
                x[i] ^= 1950;
                break;
            case 1705:
                x[i] ^= 2421;
                break;
            case 1706:
                x[i] ^= 425;
                break;
            case 1707:
                x[i] ^= 4025;
                break;
            case 1708:
                x[i] ^= 872;
                break;
            case 1709:
                x[i] ^= 816;
                break;
            case 1710:
                x[i] ^= 3246;
                break;
            case 1711:
                x[i] ^= 1296;
                break;
            case 1712:
                x[i] ^= 1701;
                break;
            case 1713:
                x[i] ^= 4037;
                break;
            case 1714:
                x[i] ^= 1045;
                break;
            case 1715:
                x[i] ^= 3821;
                break;
            case 1716:
                x[i] ^= 1772;
                break;
            case 1717:
                x[i] ^= 634;
                break;
            case 1718:
                x[i] ^= 3242;
                break;
            case 1719:
                x[i] ^= 3505;
                break;
            case 1720:
                x[i] ^= 1146;
                break;
            case 1721:
                x[i] ^= 3730;
                break;
            case 1722:
                x[i] ^= 1470;
                break;
            case 1723:
                x[i] ^= 3008;
                break;
            case 1724:
                x[i] ^= 1191;
                break;
            case 1725:
                x[i] ^= 1416;
                break;
            case 1726:
                x[i] ^= 4088;
                break;
            case 1727:
                x[i] ^= 2236;
                break;
            case 1728:
                x[i] ^= 656;
                break;
            case 1729:
                x[i] ^= 3634;
                break;
            case 1730:
                x[i] ^= 2790;
                break;
            case 1731:
                x[i] ^= 1727;
                break;
            case 1732:
                x[i] ^= 505;
                break;
            case 1733:
                x[i] ^= 3437;
                break;
            case 1734:
                x[i] ^= 2692;
                break;
            case 1735:
                x[i] ^= 2262;
                break;
            case 1736:
                x[i] ^= 642;
                break;
            case 1737:
                x[i] ^= 3608;
                break;
            case 1738:
                x[i] ^= 1469;
                break;
            case 1739:
                x[i] ^= 462;
                break;
            case 1740:
                x[i] ^= 895;
                break;
            case 1741:
                x[i] ^= 1104;
                break;
            case 1742:
                x[i] ^= 1315;
                break;
            case 1743:
                x[i] ^= 1331;
                break;
            case 1744:
                x[i] ^= 2892;
                break;
            case 1745:
                x[i] ^= 251;
                break;
            case 1746:
                x[i] ^= 2382;
                break;
            case 1747:
                x[i] ^= 1020;
                break;
            case 1748:
                x[i] ^= 688;
                break;
            case 1749:
                x[i] ^= 1569;
                break;
            case 1750:
                x[i] ^= 3607;
                break;
            case 1751:
                x[i] ^= 2151;
                break;
            case 1752:
                x[i] ^= 663;
                break;
            case 1753:
                x[i] ^= 1675;
                break;
            case 1754:
                x[i] ^= 3020;
                break;
            case 1755:
                x[i] ^= 3569;
                break;
            case 1756:
                x[i] ^= 3322;
                break;
            case 1757:
                x[i] ^= 962;
                break;
            case 1758:
                x[i] ^= 1784;
                break;
            case 1759:
                x[i] ^= 4000;
                break;
            case 1760:
                x[i] ^= 1891;
                break;
            case 1761:
                x[i] ^= 3591;
                break;
            case 1762:
                x[i] ^= 3193;
                break;
            case 1763:
                x[i] ^= 3100;
                break;
            case 1764:
                x[i] ^= 2477;
                break;
            case 1765:
                x[i] ^= 2588;
                break;
            case 1766:
                x[i] ^= 3618;
                break;
            case 1767:
                x[i] ^= 2552;
                break;
            case 1768:
                x[i] ^= 3484;
                break;
            case 1769:
                x[i] ^= 2871;
                break;
            case 1770:
                x[i] ^= 1570;
                break;
            case 1771:
                x[i] ^= 1525;
                break;
            case 1772:
                x[i] ^= 327;
                break;
            case 1773:
                x[i] ^= 2346;
                break;
            case 1774:
                x[i] ^= 1291;
                break;
            case 1775:
                x[i] ^= 2887;
                break;
            case 1776:
                x[i] ^= 1615;
                break;
            case 1777:
                x[i] ^= 3887;
                break;
            case 1778:
                x[i] ^= 347;
                break;
            case 1779:
                x[i] ^= 2378;
                break;
            case 1780:
                x[i] ^= 3154;
                break;
            case 1781:
                x[i] ^= 747;
                break;
            case 1782:
                x[i] ^= 3186;
                break;
            case 1783:
                x[i] ^= 2962;
                break;
            case 1784:
                x[i] ^= 2120;
                break;
            case 1785:
                x[i] ^= 16;
                break;
            case 1786:
                x[i] ^= 1405;
                break;
            case 1787:
                x[i] ^= 1435;
                break;
            case 1788:
                x[i] ^= 772;
                break;
            case 1789:
                x[i] ^= 2837;
                break;
            case 1790:
                x[i] ^= 2487;
                break;
            case 1791:
                x[i] ^= 442;
                break;
            case 1792:
                x[i] ^= 3398;
                break;
            case 1793:
                x[i] ^= 1036;
                break;
            case 1794:
                x[i] ^= 111;
                break;
            case 1795:
                x[i] ^= 1832;
                break;
            case 1796:
                x[i] ^= 777;
                break;
            case 1797:
                x[i] ^= 2314;
                break;
            case 1798:
                x[i] ^= 2490;
                break;
            case 1799:
                x[i] ^= 2636;
                break;
            case 1800:
                x[i] ^= 3583;
                break;
            case 1801:
                x[i] ^= 630;
                break;
            case 1802:
                x[i] ^= 2008;
                break;
            case 1803:
                x[i] ^= 3861;
                break;
            case 1804:
                x[i] ^= 678;
                break;
            case 1805:
                x[i] ^= 2178;
                break;
            case 1806:
                x[i] ^= 1332;
                break;
            case 1807:
                x[i] ^= 3472;
                break;
            case 1808:
                x[i] ^= 1777;
                break;
            case 1809:
                x[i] ^= 2927;
                break;
            case 1810:
                x[i] ^= 1705;
                break;
            case 1811:
                x[i] ^= 432;
                break;
            case 1812:
                x[i] ^= 3002;
                break;
            case 1813:
                x[i] ^= 4024;
                break;
            case 1814:
                x[i] ^= 3544;
                break;
            case 1815:
                x[i] ^= 322;
                break;
            case 1816:
                x[i] ^= 1771;
                break;
            case 1817:
                x[i] ^= 1595;
                break;
            case 1818:
                x[i] ^= 2583;
                break;
            case 1819:
                x[i] ^= 2724;
                break;
            case 1820:
                x[i] ^= 3107;
                break;
            case 1821:
                x[i] ^= 1623;
                break;
            case 1822:
                x[i] ^= 3688;
                break;
            case 1823:
                x[i] ^= 3428;
                break;
            case 1824:
                x[i] ^= 238;
                break;
            case 1825:
                x[i] ^= 955;
                break;
            case 1826:
                x[i] ^= 4061;
                break;
            case 1827:
                x[i] ^= 2444;
                break;
            case 1828:
                x[i] ^= 263;
                break;
            case 1829:
                x[i] ^= 1241;
                break;
            case 1830:
                x[i] ^= 2922;
                break;
            case 1831:
                x[i] ^= 1624;
                break;
            case 1832:
                x[i] ^= 2514;
                break;
            case 1833:
                x[i] ^= 3041;
                break;
            case 1834:
                x[i] ^= 4016;
                break;
            case 1835:
                x[i] ^= 3128;
                break;
            case 1836:
                x[i] ^= 1728;
                break;
            case 1837:
                x[i] ^= 1746;
                break;
            case 1838:
                x[i] ^= 2420;
                break;
            case 1839:
                x[i] ^= 2870;
                break;
            case 1840:
                x[i] ^= 1588;
                break;
            case 1841:
                x[i] ^= 1672;
                break;
            case 1842:
                x[i] ^= 1872;
                break;
            case 1843:
                x[i] ^= 3912;
                break;
            case 1844:
                x[i] ^= 1243;
                break;
            case 1845:
                x[i] ^= 1258;
                break;
            case 1846:
                x[i] ^= 2890;
                break;
            case 1847:
                x[i] ^= 541;
                break;
            case 1848:
                x[i] ^= 1472;
                break;
            case 1849:
                x[i] ^= 140;
                break;
            case 1850:
                x[i] ^= 797;
                break;
            case 1851:
                x[i] ^= 3839;
                break;
            case 1852:
                x[i] ^= 2492;
                break;
            case 1853:
                x[i] ^= 3823;
                break;
            case 1854:
                x[i] ^= 2358;
                break;
            case 1855:
                x[i] ^= 2397;
                break;
            case 1856:
                x[i] ^= 87;
                break;
            case 1857:
                x[i] ^= 761;
                break;
            case 1858:
                x[i] ^= 698;
                break;
            case 1859:
                x[i] ^= 3542;
                break;
            case 1860:
                x[i] ^= 2242;
                break;
            case 1861:
                x[i] ^= 330;
                break;
            case 1862:
                x[i] ^= 2704;
                break;
            case 1863:
                x[i] ^= 1236;
                break;
            case 1864:
                x[i] ^= 2516;
                break;
            case 1865:
                x[i] ^= 1276;
                break;
            case 1866:
                x[i] ^= 1857;
                break;
            case 1867:
                x[i] ^= 1166;
                break;
            case 1868:
                x[i] ^= 1148;
                break;
            case 1869:
                x[i] ^= 794;
                break;
            case 1870:
                x[i] ^= 2844;
                break;
            case 1871:
                x[i] ^= 3266;
                break;
            case 1872:
                x[i] ^= 2156;
                break;
            case 1873:
                x[i] ^= 285;
                break;
            case 1874:
                x[i] ^= 475;
                break;
            case 1875:
                x[i] ^= 643;
                break;
            case 1876:
                x[i] ^= 1079;
                break;
            case 1877:
                x[i] ^= 2433;
                break;
            case 1878:
                x[i] ^= 1217;
                break;
            case 1879:
                x[i] ^= 3763;
                break;
            case 1880:
                x[i] ^= 1919;
                break;
            case 1881:
                x[i] ^= 850;
                break;
            case 1882:
                x[i] ^= 448;
                break;
            case 1883:
                x[i] ^= 3364;
                break;
            case 1884:
                x[i] ^= 2901;
                break;
            case 1885:
                x[i] ^= 2049;
                break;
            case 1886:
                x[i] ^= 1787;
                break;
            case 1887:
                x[i] ^= 765;
                break;
            case 1888:
                x[i] ^= 3511;
                break;
            case 1889:
                x[i] ^= 709;
                break;
            case 1890:
                x[i] ^= 3483;
                break;
            case 1891:
                x[i] ^= 1686;
                break;
            case 1892:
                x[i] ^= 3028;
                break;
            case 1893:
                x[i] ^= 974;
                break;
            case 1894:
                x[i] ^= 2549;
                break;
            case 1895:
                x[i] ^= 3399;
                break;
            case 1896:
                x[i] ^= 1438;
                break;
            case 1897:
                x[i] ^= 1878;
                break;
            case 1898:
                x[i] ^= 1338;
                break;
            case 1899:
                x[i] ^= 1281;
                break;
            case 1900:
                x[i] ^= 3911;
                break;
            case 1901:
                x[i] ^= 3744;
                break;
            case 1902:
                x[i] ^= 2897;
                break;
            case 1903:
                x[i] ^= 2996;
                break;
            case 1904:
                x[i] ^= 3928;
                break;
            case 1905:
                x[i] ^= 4040;
                break;
            case 1906:
                x[i] ^= 203;
                break;
            case 1907:
                x[i] ^= 2533;
                break;
            case 1908:
                x[i] ^= 2727;
                break;
            case 1909:
                x[i] ^= 2594;
                break;
            case 1910:
                x[i] ^= 2047;
                break;
            case 1911:
                x[i] ^= 805;
                break;
            case 1912:
                x[i] ^= 2764;
                break;
            case 1913:
                x[i] ^= 3894;
                break;
            case 1914:
                x[i] ^= 2624;
                break;
            case 1915:
                x[i] ^= 1463;
                break;
            case 1916:
                x[i] ^= 3465;
                break;
            case 1917:
                x[i] ^= 2400;
                break;
            case 1918:
                x[i] ^= 1309;
                break;
            case 1919:
                x[i] ^= 3117;
                break;
            case 1920:
                x[i] ^= 1156;
                break;
            case 1921:
                x[i] ^= 1337;
                break;
            case 1922:
                x[i] ^= 2640;
                break;
            case 1923:
                x[i] ^= 2077;
                break;
            case 1924:
                x[i] ^= 3884;
                break;
            case 1925:
                x[i] ^= 1362;
                break;
            case 1926:
                x[i] ^= 2839;
                break;
            case 1927:
                x[i] ^= 350;
                break;
            case 1928:
                x[i] ^= 3825;
                break;
            case 1929:
                x[i] ^= 661;
                break;
            case 1930:
                x[i] ^= 1442;
                break;
            case 1931:
                x[i] ^= 2467;
                break;
            case 1932:
                x[i] ^= 3675;
                break;
            case 1933:
                x[i] ^= 3550;
                break;
            case 1934:
                x[i] ^= 571;
                break;
            case 1935:
                x[i] ^= 2949;
                break;
            case 1936:
                x[i] ^= 2964;
                break;
            case 1937:
                x[i] ^= 3073;
                break;
            case 1938:
                x[i] ^= 1708;
                break;
            case 1939:
                x[i] ^= 810;
                break;
            case 1940:
                x[i] ^= 4043;
                break;
            case 1941:
                x[i] ^= 704;
                break;
            case 1942:
                x[i] ^= 2551;
                break;
            case 1943:
                x[i] ^= 3414;
                break;
            case 1944:
                x[i] ^= 3330;
                break;
            case 1945:
                x[i] ^= 576;
                break;
            case 1946:
                x[i] ^= 1448;
                break;
            case 1947:
                x[i] ^= 721;
                break;
            case 1948:
                x[i] ^= 2512;
                break;
            case 1949:
                x[i] ^= 1480;
                break;
            case 1950:
                x[i] ^= 1907;
                break;
            case 1951:
                x[i] ^= 2931;
                break;
            case 1952:
                x[i] ^= 242;
                break;
            case 1953:
                x[i] ^= 1740;
                break;
            case 1954:
                x[i] ^= 555;
                break;
            case 1955:
                x[i] ^= 2561;
                break;
            case 1956:
                x[i] ^= 1170;
                break;
            case 1957:
                x[i] ^= 1192;
                break;
            case 1958:
                x[i] ^= 3578;
                break;
            case 1959:
                x[i] ^= 3106;
                break;
            case 1960:
                x[i] ^= 740;
                break;
            case 1961:
                x[i] ^= 2064;
                break;
            case 1962:
                x[i] ^= 1011;
                break;
            case 1963:
                x[i] ^= 1279;
                break;
            case 1964:
                x[i] ^= 2039;
                break;
            case 1965:
                x[i] ^= 167;
                break;
            case 1966:
                x[i] ^= 145;
                break;
            case 1967:
                x[i] ^= 135;
                break;
            case 1968:
                x[i] ^= 3253;
                break;
            case 1969:
                x[i] ^= 2543;
                break;
            case 1970:
                x[i] ^= 268;
                break;
            case 1971:
                x[i] ^= 378;
                break;
            case 1972:
                x[i] ^= 1946;
                break;
            case 1973:
                x[i] ^= 2022;
                break;
            case 1974:
                x[i] ^= 423;
                break;
            case 1975:
                x[i] ^= 1896;
                break;
            case 1976:
                x[i] ^= 1673;
                break;
            case 1977:
                x[i] ^= 1702;
                break;
            case 1978:
                x[i] ^= 3219;
                break;
            case 1979:
                x[i] ^= 961;
                break;
            case 1980:
                x[i] ^= 1400;
                break;
            case 1981:
                x[i] ^= 950;
                break;
            case 1982:
                x[i] ^= 1075;
                break;
            case 1983:
                x[i] ^= 1043;
                break;
            case 1984:
                x[i] ^= 2074;
                break;
            case 1985:
                x[i] ^= 1600;
                break;
            case 1986:
                x[i] ^= 1246;
                break;
            case 1987:
                x[i] ^= 1591;
                break;
            case 1988:
                x[i] ^= 3630;
                break;
            case 1989:
                x[i] ^= 985;
                break;
            case 1990:
                x[i] ^= 2113;
                break;
            case 1991:
                x[i] ^= 779;
                break;
            case 1992:
                x[i] ^= 3032;
                break;
            case 1993:
                x[i] ^= 3108;
                break;
            case 1994:
                x[i] ^= 4036;
                break;
            case 1995:
                x[i] ^= 290;
                break;
            case 1996:
                x[i] ^= 2627;
                break;
            case 1997:
                x[i] ^= 2302;
                break;
            case 1998:
                x[i] ^= 1646;
                break;
            case 1999:
                x[i] ^= 3049;
                break;
            case 2000:
                x[i] ^= 3519;
                break;
            case 2001:
                x[i] ^= 3856;
                break;
            case 2002:
                x[i] ^= 1027;
                break;
            case 2003:
                x[i] ^= 3152;
                break;
            case 2004:
                x[i] ^= 1048;
                break;
            case 2005:
                x[i] ^= 1092;
                break;
            case 2006:
                x[i] ^= 2446;
                break;
            case 2007:
                x[i] ^= 1679;
                break;
            case 2008:
                x[i] ^= 1160;
                break;
            case 2009:
                x[i] ^= 969;
                break;
            case 2010:
                x[i] ^= 2279;
                break;
            case 2011:
                x[i] ^= 3265;
                break;
            case 2012:
                x[i] ^= 834;
                break;
            case 2013:
                x[i] ^= 132;
                break;
            case 2014:
                x[i] ^= 1520;
                break;
            case 2015:
                x[i] ^= 1622;
                break;
            case 2016:
                x[i] ^= 3016;
                break;
            case 2017:
                x[i] ^= 3958;
                break;
            case 2018:
                x[i] ^= 1524;
                break;
            case 2019:
                x[i] ^= 2083;
                break;
            case 2020:
                x[i] ^= 2032;
                break;
            case 2021:
                x[i] ^= 2896;
                break;
            case 2022:
                x[i] ^= 529;
                break;
            case 2023:
                x[i] ^= 2509;
                break;
            case 2024:
                x[i] ^= 3863;
                break;
            case 2025:
                x[i] ^= 2832;
                break;
            case 2026:
                x[i] ^= 990;
                break;
            case 2027:
                x[i] ^= 2820;
                break;
            case 2028:
                x[i] ^= 3530;
                break;
            case 2029:
                x[i] ^= 414;
                break;
            case 2030:
                x[i] ^= 1968;
                break;
            case 2031:
                x[i] ^= 427;
                break;
            case 2032:
                x[i] ^= 506;
                break;
            case 2033:
                x[i] ^= 3279;
                break;
            case 2034:
                x[i] ^= 1513;
                break;
            case 2035:
                x[i] ^= 1371;
                break;
            case 2036:
                x[i] ^= 2851;
                break;
            case 2037:
                x[i] ^= 407;
                break;
            case 2038:
                x[i] ^= 332;
                break;
            case 2039:
                x[i] ^= 3698;
                break;
            case 2040:
                x[i] ^= 2272;
                break;
            case 2041:
                x[i] ^= 2878;
                break;
            case 2042:
                x[i] ^= 1597;
                break;
            case 2043:
                x[i] ^= 123;
                break;
            case 2044:
                x[i] ^= 2604;
                break;
            case 2045:
                x[i] ^= 2217;
                break;
            case 2046:
                x[i] ^= 2031;
                break;
            case 2047:
                x[i] ^= 3348;
                break;
            case 2048:
                x[i] ^= 2623;
                break;
            case 2049:
                x[i] ^= 3102;
                break;
            case 2050:
                x[i] ^= 3557;
                break;
            case 2051:
                x[i] ^= 1822;
                break;
            case 2052:
                x[i] ^= 1889;
                break;
            case 2053:
                x[i] ^= 3315;
                break;
            case 2054:
                x[i] ^= 1414;
                break;
            case 2055:
                x[i] ^= 843;
                break;
            case 2056:
                x[i] ^= 2180;
                break;
            case 2057:
                x[i] ^= 4004;
                break;
            case 2058:
                x[i] ^= 892;
                break;
            case 2059:
                x[i] ^= 716;
                break;
            case 2060:
                x[i] ^= 2781;
                break;
            case 2061:
                x[i] ^= 58;
                break;
            case 2062:
                x[i] ^= 3366;
                break;
            case 2063:
                x[i] ^= 20;
                break;
            case 2064:
                x[i] ^= 218;
                break;
            case 2065:
                x[i] ^= 2493;
                break;
            case 2066:
                x[i] ^= 1905;
                break;
            case 2067:
                x[i] ^= 3551;
                break;
            case 2068:
                x[i] ^= 4092;
                break;
            case 2069:
                x[i] ^= 2237;
                break;
            case 2070:
                x[i] ^= 2615;
                break;
            case 2071:
                x[i] ^= 3122;
                break;
            case 2072:
                x[i] ^= 1410;
                break;
            case 2073:
                x[i] ^= 2750;
                break;
            case 2074:
                x[i] ^= 2229;
                break;
            case 2075:
                x[i] ^= 524;
                break;
            case 2076:
                x[i] ^= 3033;
                break;
            case 2077:
                x[i] ^= 4082;
                break;
            case 2078:
                x[i] ^= 3943;
                break;
            case 2079:
                x[i] ^= 3163;
                break;
            case 2080:
                x[i] ^= 1974;
                break;
            case 2081:
                x[i] ^= 3523;
                break;
            case 2082:
                x[i] ^= 594;
                break;
            case 2083:
                x[i] ^= 1557;
                break;
            case 2084:
                x[i] ^= 2036;
                break;
            case 2085:
                x[i] ^= 1643;
                break;
            case 2086:
                x[i] ^= 453;
                break;
            case 2087:
                x[i] ^= 267;
                break;
            case 2088:
                x[i] ^= 3312;
                break;
            case 2089:
                x[i] ^= 2463;
                break;
            case 2090:
                x[i] ^= 1710;
                break;
            case 2091:
                x[i] ^= 519;
                break;
            case 2092:
                x[i] ^= 2152;
                break;
            case 2093:
                x[i] ^= 1204;
                break;
            case 2094:
                x[i] ^= 809;
                break;
            case 2095:
                x[i] ^= 1341;
                break;
            case 2096:
                x[i] ^= 458;
                break;
            case 2097:
                x[i] ^= 631;
                break;
            case 2098:
                x[i] ^= 2098;
                break;
            case 2099:
                x[i] ^= 109;
                break;
            case 2100:
                x[i] ^= 1100;
                break;
            case 2101:
                x[i] ^= 1122;
                break;
            case 2102:
                x[i] ^= 1537;
                break;
            case 2103:
                x[i] ^= 3711;
                break;
            case 2104:
                x[i] ^= 702;
                break;
            case 2105:
                x[i] ^= 2943;
                break;
            case 2106:
                x[i] ^= 1693;
                break;
            case 2107:
                x[i] ^= 876;
                break;
            case 2108:
                x[i] ^= 4041;
                break;
            case 2109:
                x[i] ^= 412;
                break;
            case 2110:
                x[i] ^= 222;
                break;
            case 2111:
                x[i] ^= 2662;
                break;
            case 2112:
                x[i] ^= 3212;
                break;
            case 2113:
                x[i] ^= 2013;
                break;
            case 2114:
                x[i] ^= 839;
                break;
            case 2115:
                x[i] ^= 2735;
                break;
            case 2116:
                x[i] ^= 32;
                break;
            case 2117:
                x[i] ^= 815;
                break;
            case 2118:
                x[i] ^= 2368;
                break;
            case 2119:
                x[i] ^= 416;
                break;
            case 2120:
                x[i] ^= 95;
                break;
            case 2121:
                x[i] ^= 4083;
                break;
            case 2122:
                x[i] ^= 1674;
                break;
            case 2123:
                x[i] ^= 231;
                break;
            case 2124:
                x[i] ^= 578;
                break;
            case 2125:
                x[i] ^= 3920;
                break;
            case 2126:
                x[i] ^= 625;
                break;
            case 2127:
                x[i] ^= 3954;
                break;
            case 2128:
                x[i] ^= 0;
                break;
            case 2129:
                x[i] ^= 1456;
                break;
            case 2130:
                x[i] ^= 601;
                break;
            case 2131:
                x[i] ^= 2203;
                break;
            case 2132:
                x[i] ^= 3490;
                break;
            case 2133:
                x[i] ^= 3765;
                break;
            case 2134:
                x[i] ^= 1225;
                break;
            case 2135:
                x[i] ^= 2760;
                break;
            case 2136:
                x[i] ^= 1035;
                break;
            case 2137:
                x[i] ^= 3955;
                break;
            case 2138:
                x[i] ^= 1389;
                break;
            case 2139:
                x[i] ^= 1266;
                break;
            case 2140:
                x[i] ^= 342;
                break;
            case 2141:
                x[i] ^= 2969;
                break;
            case 2142:
                x[i] ^= 1095;
                break;
            case 2143:
                x[i] ^= 139;
                break;
            case 2144:
                x[i] ^= 3142;
                break;
            case 2145:
                x[i] ^= 3696;
                break;
            case 2146:
                x[i] ^= 2210;
                break;
            case 2147:
                x[i] ^= 1785;
                break;
            case 2148:
                x[i] ^= 3495;
                break;
            case 2149:
                x[i] ^= 329;
                break;
            case 2150:
                x[i] ^= 1203;
                break;
            case 2151:
                x[i] ^= 3785;
                break;
            case 2152:
                x[i] ^= 469;
                break;
            case 2153:
                x[i] ^= 3305;
                break;
            case 2154:
                x[i] ^= 2486;
                break;
            case 2155:
                x[i] ^= 2127;
                break;
            case 2156:
                x[i] ^= 1535;
                break;
            case 2157:
                x[i] ^= 3524;
                break;
            case 2158:
                x[i] ^= 1097;
                break;
            case 2159:
                x[i] ^= 3660;
                break;
            case 2160:
                x[i] ^= 2384;
                break;
            case 2161:
                x[i] ^= 863;
                break;
            case 2162:
                x[i] ^= 3241;
                break;
            case 2163:
                x[i] ^= 1397;
                break;
            case 2164:
                x[i] ^= 3454;
                break;
            case 2165:
                x[i] ^= 1149;
                break;
            case 2166:
                x[i] ^= 4033;
                break;
            case 2167:
                x[i] ^= 1282;
                break;
            case 2168:
                x[i] ^= 15;
                break;
            case 2169:
                x[i] ^= 3489;
                break;
            case 2170:
                x[i] ^= 1720;
                break;
            case 2171:
                x[i] ^= 449;
                break;
            case 2172:
                x[i] ^= 3560;
                break;
            case 2173:
                x[i] ^= 1247;
                break;
            case 2174:
                x[i] ^= 4047;
                break;
            case 2175:
                x[i] ^= 2684;
                break;
            case 2176:
                x[i] ^= 1025;
                break;
            case 2177:
                x[i] ^= 1494;
                break;
            case 2178:
                x[i] ^= 1200;
                break;
            case 2179:
                x[i] ^= 2691;
                break;
            case 2180:
                x[i] ^= 700;
                break;
            case 2181:
                x[i] ^= 3904;
                break;
            case 2182:
                x[i] ^= 3804;
                break;
            case 2183:
                x[i] ^= 1668;
                break;
            case 2184:
                x[i] ^= 3220;
                break;
            case 2185:
                x[i] ^= 3582;
                break;
            case 2186:
                x[i] ^= 1829;
                break;
            case 2187:
                x[i] ^= 937;
                break;
            case 2188:
                x[i] ^= 2030;
                break;
            case 2189:
                x[i] ^= 3543;
                break;
            case 2190:
                x[i] ^= 3683;
                break;
            case 2191:
                x[i] ^= 984;
                break;
            case 2192:
                x[i] ^= 219;
                break;
            case 2193:
                x[i] ^= 1301;
                break;
            case 2194:
                x[i] ^= 3522;
                break;
            case 2195:
                x[i] ^= 2182;
                break;
            case 2196:
                x[i] ^= 1651;
                break;
            case 2197:
                x[i] ^= 3754;
                break;
            case 2198:
                x[i] ^= 2481;
                break;
            case 2199:
                x[i] ^= 966;
                break;
            case 2200:
                x[i] ^= 3443;
                break;
            case 2201:
                x[i] ^= 2565;
                break;
            case 2202:
                x[i] ^= 3704;
                break;
            case 2203:
                x[i] ^= 1478;
                break;
            case 2204:
                x[i] ^= 3991;
                break;
            case 2205:
                x[i] ^= 1172;
                break;
            case 2206:
                x[i] ^= 3078;
                break;
            case 2207:
                x[i] ^= 1536;
                break;
            case 2208:
                x[i] ^= 296;
                break;
            case 2209:
                x[i] ^= 2795;
                break;
            case 2210:
                x[i] ^= 1900;
                break;
            case 2211:
                x[i] ^= 4017;
                break;
            case 2212:
                x[i] ^= 2693;
                break;
            case 2213:
                x[i] ^= 1313;
                break;
            case 2214:
                x[i] ^= 1272;
                break;
            case 2215:
                x[i] ^= 3866;
                break;
            case 2216:
                x[i] ^= 570;
                break;
            case 2217:
                x[i] ^= 1661;
                break;
            case 2218:
                x[i] ^= 2513;
                break;
            case 2219:
                x[i] ^= 593;
                break;
            case 2220:
                x[i] ^= 713;
                break;
            case 2221:
                x[i] ^= 1299;
                break;
            case 2222:
                x[i] ^= 2427;
                break;
            case 2223:
                x[i] ^= 2508;
                break;
            case 2224:
                x[i] ^= 2774;
                break;
            case 2225:
                x[i] ^= 2488;
                break;
            case 2226:
                x[i] ^= 543;
                break;
            case 2227:
                x[i] ^= 1504;
                break;
            case 2228:
                x[i] ^= 2580;
                break;
            case 2229:
                x[i] ^= 1068;
                break;
            case 2230:
                x[i] ^= 1734;
                break;
            case 2231:
                x[i] ^= 2859;
                break;
            case 2232:
                x[i] ^= 1861;
                break;
            case 2233:
                x[i] ^= 569;
                break;
            case 2234:
                x[i] ^= 1542;
                break;
            case 2235:
                x[i] ^= 1255;
                break;
            case 2236:
                x[i] ^= 2351;
                break;
            case 2237:
                x[i] ^= 1725;
                break;
            case 2238:
                x[i] ^= 1605;
                break;
            case 2239:
                x[i] ^= 1545;
                break;
            case 2240:
                x[i] ^= 2102;
                break;
            case 2241:
                x[i] ^= 3221;
                break;
            case 2242:
                x[i] ^= 710;
                break;
            case 2243:
                x[i] ^= 2166;
                break;
            case 2244:
                x[i] ^= 2537;
                break;
            case 2245:
                x[i] ^= 2762;
                break;
            case 2246:
                x[i] ^= 3770;
                break;
            case 2247:
                x[i] ^= 2154;
                break;
            case 2248:
                x[i] ^= 2365;
                break;
            case 2249:
                x[i] ^= 1154;
                break;
            case 2250:
                x[i] ^= 3597;
                break;
            case 2251:
                x[i] ^= 3057;
                break;
            case 2252:
                x[i] ^= 1180;
                break;
            case 2253:
                x[i] ^= 3412;
                break;
            case 2254:
                x[i] ^= 738;
                break;
            case 2255:
                x[i] ^= 3072;
                break;
            case 2256:
                x[i] ^= 3536;
                break;
            case 2257:
                x[i] ^= 1085;
                break;
            case 2258:
                x[i] ^= 1632;
                break;
            case 2259:
                x[i] ^= 2911;
                break;
            case 2260:
                x[i] ^= 1047;
                break;
            case 2261:
                x[i] ^= 722;
                break;
            case 2262:
                x[i] ^= 3700;
                break;
            case 2263:
                x[i] ^= 3989;
                break;
            case 2264:
                x[i] ^= 2238;
                break;
            case 2265:
                x[i] ^= 36;
                break;
            case 2266:
                x[i] ^= 628;
                break;
            case 2267:
                x[i] ^= 2472;
                break;
            case 2268:
                x[i] ^= 1467;
                break;
            case 2269:
                x[i] ^= 929;
                break;
            case 2270:
                x[i] ^= 3329;
                break;
            case 2271:
                x[i] ^= 1415;
                break;
            case 2272:
                x[i] ^= 724;
                break;
            case 2273:
                x[i] ^= 168;
                break;
            case 2274:
                x[i] ^= 1500;
                break;
            case 2275:
                x[i] ^= 2702;
                break;
            case 2276:
                x[i] ^= 155;
                break;
            case 2277:
                x[i] ^= 3390;
                break;
            case 2278:
                x[i] ^= 3334;
                break;
            case 2279:
                x[i] ^= 418;
                break;
            case 2280:
                x[i] ^= 1962;
                break;
            case 2281:
                x[i] ^= 1778;
                break;
            case 2282:
                x[i] ^= 2256;
                break;
            case 2283:
                x[i] ^= 2224;
                break;
            case 2284:
                x[i] ^= 3507;
                break;
            case 2285:
                x[i] ^= 3286;
                break;
            case 2286:
                x[i] ^= 2244;
                break;
            case 2287:
                x[i] ^= 3332;
                break;
            case 2288:
                x[i] ^= 1379;
                break;
            case 2289:
                x[i] ^= 38;
                break;
            case 2290:
                x[i] ^= 2714;
                break;
            case 2291:
                x[i] ^= 3534;
                break;
            case 2292:
                x[i] ^= 4087;
                break;
            case 2293:
                x[i] ^= 403;
                break;
            case 2294:
                x[i] ^= 1608;
                break;
            case 2295:
                x[i] ^= 3272;
                break;
            case 2296:
                x[i] ^= 2409;
                break;
            case 2297:
                x[i] ^= 2003;
                break;
            case 2298:
                x[i] ^= 3116;
                break;
            case 2299:
                x[i] ^= 1186;
                break;
            case 2300:
                x[i] ^= 2671;
                break;
            case 2301:
                x[i] ^= 1197;
                break;
            case 2302:
                x[i] ^= 2756;
                break;
            case 2303:
                x[i] ^= 2035;
                break;
            case 2304:
                x[i] ^= 147;
                break;
            case 2305:
                x[i] ^= 2453;
                break;
            case 2306:
                x[i] ^= 1386;
                break;
            case 2307:
                x[i] ^= 1195;
                break;
            case 2308:
                x[i] ^= 833;
                break;
            case 2309:
                x[i] ^= 3729;
                break;
            case 2310:
                x[i] ^= 2096;
                break;
            case 2311:
                x[i] ^= 4086;
                break;
            case 2312:
                x[i] ^= 3453;
                break;
            case 2313:
                x[i] ^= 2150;
                break;
            case 2314:
                x[i] ^= 901;
                break;
            case 2315:
                x[i] ^= 3693;
                break;
            case 2316:
                x[i] ^= 2776;
                break;
            case 2317:
                x[i] ^= 2326;
                break;
            case 2318:
                x[i] ^= 315;
                break;
            case 2319:
                x[i] ^= 3140;
                break;
            case 2320:
                x[i] ^= 302;
                break;
            case 2321:
                x[i] ^= 174;
                break;
            case 2322:
                x[i] ^= 1464;
                break;
            case 2323:
                x[i] ^= 2918;
                break;
            case 2324:
                x[i] ^= 3175;
                break;
            case 2325:
                x[i] ^= 3161;
                break;
            case 2326:
                x[i] ^= 1368;
                break;
            case 2327:
                x[i] ^= 3368;
                break;
            case 2328:
                x[i] ^= 1631;
                break;
            case 2329:
                x[i] ^= 658;
                break;
            case 2330:
                x[i] ^= 1691;
                break;
            case 2331:
                x[i] ^= 2452;
                break;
            case 2332:
                x[i] ^= 160;
                break;
            case 2333:
                x[i] ^= 2941;
                break;
            case 2334:
                x[i] ^= 1511;
                break;
            case 2335:
                x[i] ^= 3135;
                break;
            case 2336:
                x[i] ^= 1880;
                break;
            case 2337:
                x[i] ^= 926;
                break;
            case 2338:
                x[i] ^= 2673;
                break;
            case 2339:
                x[i] ^= 3214;
                break;
            case 2340:
                x[i] ^= 2081;
                break;
            case 2341:
                x[i] ^= 539;
                break;
            case 2342:
                x[i] ^= 2066;
                break;
            case 2343:
                x[i] ^= 2688;
                break;
            case 2344:
                x[i] ^= 1374;
                break;
            case 2345:
                x[i] ^= 581;
                break;
            case 2346:
                x[i] ^= 2136;
                break;
            case 2347:
                x[i] ^= 3473;
                break;
            case 2348:
                x[i] ^= 3702;
                break;
            case 2349:
                x[i] ^= 1325;
                break;
            case 2350:
                x[i] ^= 3914;
                break;
            case 2351:
                x[i] ^= 79;
                break;
            case 2352:
                x[i] ^= 175;
                break;
            case 2353:
                x[i] ^= 319;
                break;
            case 2354:
                x[i] ^= 3435;
                break;
            case 2355:
                x[i] ^= 1145;
                break;
            case 2356:
                x[i] ^= 2652;
                break;
            case 2357:
                x[i] ^= 3780;
                break;
            case 2358:
                x[i] ^= 4079;
                break;
            case 2359:
                x[i] ^= 2007;
                break;
            case 2360:
                x[i] ^= 2539;
                break;
            case 2361:
                x[i] ^= 2730;
                break;
            case 2362:
                x[i] ^= 192;
                break;
            case 2363:
                x[i] ^= 1506;
                break;
            case 2364:
                x[i] ^= 751;
                break;
            case 2365:
                x[i] ^= 248;
                break;
            case 2366:
                x[i] ^= 2390;
                break;
            case 2367:
                x[i] ^= 1460;
                break;
            case 2368:
                x[i] ^= 1612;
                break;
            case 2369:
                x[i] ^= 441;
                break;
            case 2370:
                x[i] ^= 2255;
                break;
            case 2371:
                x[i] ^= 1139;
                break;
            case 2372:
                x[i] ^= 1307;
                break;
            case 2373:
                x[i] ^= 2498;
                break;
            case 2374:
                x[i] ^= 637;
                break;
            case 2375:
                x[i] ^= 1684;
                break;
            case 2376:
                x[i] ^= 763;
                break;
            case 2377:
                x[i] ^= 2273;
                break;
            case 2378:
                x[i] ^= 2616;
                break;
            case 2379:
                x[i] ^= 2364;
                break;
            case 2380:
                x[i] ^= 2619;
                break;
            case 2381:
                x[i] ^= 2813;
                break;
            case 2382:
                x[i] ^= 2758;
                break;
            case 2383:
                x[i] ^= 3844;
                break;
            case 2384:
                x[i] ^= 45;
                break;
            case 2385:
                x[i] ^= 3397;
                break;
            case 2386:
                x[i] ^= 189;
                break;
            case 2387:
                x[i] ^= 3502;
                break;
            case 2388:
                x[i] ^= 914;
                break;
            case 2389:
                x[i] ^= 3964;
                break;
            case 2390:
                x[i] ^= 1387;
                break;
            case 2391:
                x[i] ^= 209;
                break;
            case 2392:
                x[i] ^= 2955;
                break;
            case 2393:
                x[i] ^= 1532;
                break;
            case 2394:
                x[i] ^= 2440;
                break;
            case 2395:
                x[i] ^= 1913;
                break;
            case 2396:
                x[i] ^= 2567;
                break;
            case 2397:
                x[i] ^= 2285;
                break;
            case 2398:
                x[i] ^= 2924;
                break;
            case 2399:
                x[i] ^= 3895;
                break;
            case 2400:
                x[i] ^= 1284;
                break;
            case 2401:
                x[i] ^= 690;
                break;
            case 2402:
                x[i] ^= 3905;
                break;
            case 2403:
                x[i] ^= 1999;
                break;
            case 2404:
                x[i] ^= 2423;
                break;
            case 2405:
                x[i] ^= 2602;
                break;
            case 2406:
                x[i] ^= 2505;
                break;
            case 2407:
                x[i] ^= 775;
                break;
            case 2408:
                x[i] ^= 184;
                break;
            case 2409:
                x[i] ^= 2290;
                break;
            case 2410:
                x[i] ^= 2414;
                break;
            case 2411:
                x[i] ^= 22;
                break;
            case 2412:
                x[i] ^= 1367;
                break;
            case 2413:
                x[i] ^= 684;
                break;
            case 2414:
                x[i] ^= 2171;
                break;
            case 2415:
                x[i] ^= 2441;
                break;
            case 2416:
                x[i] ^= 3889;
                break;
            case 2417:
                x[i] ^= 3752;
                break;
            case 2418:
                x[i] ^= 3690;
                break;
            case 2419:
                x[i] ^= 1551;
                break;
            case 2420:
                x[i] ^= 31;
                break;
            case 2421:
                x[i] ^= 1742;
                break;
            case 2422:
                x[i] ^= 3697;
                break;
            case 2423:
                x[i] ^= 3229;
                break;
            case 2424:
                x[i] ^= 286;
                break;
            case 2425:
                x[i] ^= 2929;
                break;
            case 2426:
                x[i] ^= 859;
                break;
            case 2427:
                x[i] ^= 2164;
                break;
            case 2428:
                x[i] ^= 2445;
                break;
            case 2429:
                x[i] ^= 649;
                break;
            case 2430:
                x[i] ^= 1488;
                break;
            case 2431:
                x[i] ^= 358;
                break;
            case 2432:
                x[i] ^= 1957;
                break;
            case 2433:
                x[i] ^= 2103;
                break;
            case 2434:
                x[i] ^= 295;
                break;
            case 2435:
                x[i] ^= 1827;
                break;
            case 2436:
                x[i] ^= 2118;
                break;
            case 2437:
                x[i] ^= 1093;
                break;
            case 2438:
                x[i] ^= 3104;
                break;
            case 2439:
                x[i] ^= 7;
                break;
            case 2440:
                x[i] ^= 1076;
                break;
            case 2441:
                x[i] ^= 528;
                break;
            case 2442:
                x[i] ^= 1757;
                break;
            case 2443:
                x[i] ^= 105;
                break;
            case 2444:
                x[i] ^= 161;
                break;
            case 2445:
                x[i] ^= 292;
                break;
            case 2446:
                x[i] ^= 991;
                break;
            case 2447:
                x[i] ^= 211;
                break;
            case 2448:
                x[i] ^= 568;
                break;
            case 2449:
                x[i] ^= 4008;
                break;
            case 2450:
                x[i] ^= 616;
                break;
            case 2451:
                x[i] ^= 3062;
                break;
            case 2452:
                x[i] ^= 3375;
                break;
            case 2453:
                x[i] ^= 1568;
                break;
            case 2454:
                x[i] ^= 812;
                break;
            case 2455:
                x[i] ^= 2424;
                break;
            case 2456:
                x[i] ^= 2200;
                break;
            case 2457:
                x[i] ^= 2328;
                break;
            case 2458:
                x[i] ^= 157;
                break;
            case 2459:
                x[i] ^= 379;
                break;
            case 2460:
                x[i] ^= 1017;
                break;
            case 2461:
                x[i] ^= 3680;
                break;
            case 2462:
                x[i] ^= 1687;
                break;
            case 2463:
                x[i] ^= 2135;
                break;
            case 2464:
                x[i] ^= 419;
                break;
            case 2465:
                x[i] ^= 3876;
                break;
            case 2466:
                x[i] ^= 737;
                break;
            case 2467:
                x[i] ^= 43;
                break;
            case 2468:
                x[i] ^= 2584;
                break;
            case 2469:
                x[i] ^= 3468;
                break;
            case 2470:
                x[i] ^= 2020;
                break;
            case 2471:
                x[i] ^= 1167;
                break;
            case 2472:
                x[i] ^= 2387;
                break;
            case 2473:
                x[i] ^= 3344;
                break;
            case 2474:
                x[i] ^= 537;
                break;
            case 2475:
                x[i] ^= 3439;
                break;
            case 2476:
                x[i] ^= 1395;
                break;
            case 2477:
                x[i] ^= 3854;
                break;
            case 2478:
                x[i] ^= 3347;
                break;
            case 2479:
                x[i] ^= 2737;
                break;
            case 2480:
                x[i] ^= 1789;
                break;
            case 2481:
                x[i] ^= 2298;
                break;
            case 2482:
                x[i] ^= 3922;
                break;
            case 2483:
                x[i] ^= 404;
                break;
            case 2484:
                x[i] ^= 3298;
                break;
            case 2485:
                x[i] ^= 3326;
                break;
            case 2486:
                x[i] ^= 2063;
                break;
            case 2487:
                x[i] ^= 3982;
                break;
            case 2488:
                x[i] ^= 3588;
                break;
            case 2489:
                x[i] ^= 2722;
                break;
            case 2490:
                x[i] ^= 2179;
                break;
            case 2491:
                x[i] ^= 3374;
                break;
            case 2492:
                x[i] ^= 3789;
                break;
            case 2493:
                x[i] ^= 1596;
                break;
            case 2494:
                x[i] ^= 2352;
                break;
            case 2495:
                x[i] ^= 2950;
                break;
            case 2496:
                x[i] ^= 99;
                break;
            case 2497:
                x[i] ^= 3331;
                break;
            case 2498:
                x[i] ^= 237;
                break;
            case 2499:
                x[i] ^= 2012;
                break;
            case 2500:
                x[i] ^= 2211;
                break;
            case 2501:
                x[i] ^= 2700;
                break;
            case 2502:
                x[i] ^= 2411;
                break;
            case 2503:
                x[i] ^= 3576;
                break;
            case 2504:
                x[i] ^= 3923;
                break;
            case 2505:
                x[i] ^= 2080;
                break;
            case 2506:
                x[i] ^= 1256;
                break;
            case 2507:
                x[i] ^= 2573;
                break;
            case 2508:
                x[i] ^= 2998;
                break;
            case 2509:
                x[i] ^= 1501;
                break;
            case 2510:
                x[i] ^= 3054;
                break;
            case 2511:
                x[i] ^= 1240;
                break;
            case 2512:
                x[i] ^= 1055;
                break;
            case 2513:
                x[i] ^= 3356;
                break;
            case 2514:
                x[i] ^= 1001;
                break;
            case 2515:
                x[i] ^= 1587;
                break;
            case 2516:
                x[i] ^= 3342;
                break;
            case 2517:
                x[i] ^= 3773;
                break;
            case 2518:
                x[i] ^= 3442;
                break;
            case 2519:
                x[i] ^= 1000;
                break;
            case 2520:
                x[i] ^= 44;
                break;
            case 2521:
                x[i] ^= 1184;
                break;
            case 2522:
                x[i] ^= 2857;
                break;
            case 2523:
                x[i] ^= 2220;
                break;
            case 2524:
                x[i] ^= 2740;
                break;
            case 2525:
                x[i] ^= 908;
                break;
            case 2526:
                x[i] ^= 1961;
                break;
            case 2527:
                x[i] ^= 4073;
                break;
            case 2528:
                x[i] ^= 309;
                break;
            case 2529:
                x[i] ^= 4029;
                break;
            case 2530:
                x[i] ^= 1768;
                break;
            case 2531:
                x[i] ^= 3999;
                break;
            case 2532:
                x[i] ^= 1609;
                break;
            case 2533:
                x[i] ^= 422;
                break;
            case 2534:
                x[i] ^= 2944;
                break;
            case 2535:
                x[i] ^= 2283;
                break;
            case 2536:
                x[i] ^= 920;
                break;
            case 2537:
                x[i] ^= 2295;
                break;
            case 2538:
                x[i] ^= 2489;
                break;
            case 2539:
                x[i] ^= 3046;
                break;
            case 2540:
                x[i] ^= 1718;
                break;
            case 2541:
                x[i] ^= 3631;
                break;
            case 2542:
                x[i] ^= 3488;
                break;
            case 2543:
                x[i] ^= 823;
                break;
            case 2544:
                x[i] ^= 2090;
                break;
            case 2545:
                x[i] ^= 2324;
                break;
            case 2546:
                x[i] ^= 1230;
                break;
            case 2547:
                x[i] ^= 1775;
                break;
            case 2548:
                x[i] ^= 4045;
                break;
            case 2549:
                x[i] ^= 886;
                break;
            case 2550:
                x[i] ^= 3565;
                break;
            case 2551:
                x[i] ^= 3628;
                break;
            case 2552:
                x[i] ^= 2589;
                break;
            case 2553:
                x[i] ^= 2048;
                break;
            case 2554:
                x[i] ^= 2348;
                break;
            case 2555:
                x[i] ^= 600;
                break;
            case 2556:
                x[i] ^= 2663;
                break;
            case 2557:
                x[i] ^= 3137;
                break;
            case 2558:
                x[i] ^= 1109;
                break;
            case 2559:
                x[i] ^= 369;
                break;
            case 2560:
                x[i] ^= 3321;
                break;
            case 2561:
                x[i] ^= 2831;
                break;
            case 2562:
                x[i] ^= 1233;
                break;
            case 2563:
                x[i] ^= 2639;
                break;
            case 2564:
                x[i] ^= 3596;
                break;
            case 2565:
                x[i] ^= 30;
                break;
            case 2566:
                x[i] ^= 3191;
                break;
            case 2567:
                x[i] ^= 2307;
                break;
            case 2568:
                x[i] ^= 1833;
                break;
            case 2569:
                x[i] ^= 3131;
                break;
            case 2570:
                x[i] ^= 3762;
                break;
            case 2571:
                x[i] ^= 3966;
                break;
            case 2572:
                x[i] ^= 3747;
                break;
            case 2573:
                x[i] ^= 516;
                break;
            case 2574:
                x[i] ^= 489;
                break;
            case 2575:
                x[i] ^= 2880;
                break;
            case 2576:
                x[i] ^= 2194;
                break;
            case 2577:
                x[i] ^= 3384;
                break;
            case 2578:
                x[i] ^= 4048;
                break;
            case 2579:
                x[i] ^= 781;
                break;
            case 2580:
                x[i] ^= 2699;
                break;
            case 2581:
                x[i] ^= 3485;
                break;
            case 2582:
                x[i] ^= 1531;
                break;
            case 2583:
                x[i] ^= 398;
                break;
            case 2584:
                x[i] ^= 2613;
                break;
            case 2585:
                x[i] ^= 1015;
                break;
            case 2586:
                x[i] ^= 894;
                break;
            case 2587:
                x[i] ^= 3400;
                break;
            case 2588:
                x[i] ^= 2775;
                break;
            case 2589:
                x[i] ^= 321;
                break;
            case 2590:
                x[i] ^= 3656;
                break;
            case 2591:
                x[i] ^= 3836;
                break;
            case 2592:
                x[i] ^= 1398;
                break;
            case 2593:
                x[i] ^= 288;
                break;
            case 2594:
                x[i] ^= 2289;
                break;
            case 2595:
                x[i] ^= 2226;
                break;
            case 2596:
                x[i] ^= 278;
                break;
            case 2597:
                x[i] ^= 3218;
                break;
            case 2598:
                x[i] ^= 2681;
                break;
            case 2599:
                x[i] ^= 2803;
                break;
            case 2600:
                x[i] ^= 3595;
                break;
            case 2601:
                x[i] ^= 1696;
                break;
            case 2602:
                x[i] ^= 2079;
                break;
            case 2603:
                x[i] ^= 129;
                break;
            case 2604:
                x[i] ^= 1898;
                break;
            case 2605:
                x[i] ^= 2874;
                break;
            case 2606:
                x[i] ^= 84;
                break;
            case 2607:
                x[i] ^= 258;
                break;
            case 2608:
                x[i] ^= 1840;
                break;
            case 2609:
                x[i] ^= 336;
                break;
            case 2610:
                x[i] ^= 1656;
                break;
            case 2611:
                x[i] ^= 3779;
                break;
            case 2612:
                x[i] ^= 266;
                break;
            case 2613:
                x[i] ^= 1171;
                break;
            case 2614:
                x[i] ^= 2739;
                break;
            case 2615:
                x[i] ^= 3666;
                break;
            case 2616:
                x[i] ^= 1044;
                break;
            case 2617:
                x[i] ^= 240;
                break;
            case 2618:
                x[i] ^= 385;
                break;
            case 2619:
                x[i] ^= 3063;
                break;
            case 2620:
                x[i] ^= 973;
                break;
            case 2621:
                x[i] ^= 3407;
                break;
            case 2622:
                x[i] ^= 4084;
                break;
            case 2623:
                x[i] ^= 1700;
                break;
            case 2624:
                x[i] ^= 2560;
                break;
            case 2625:
                x[i] ^= 2282;
                break;
            case 2626:
                x[i] ^= 1327;
                break;
            case 2627:
                x[i] ^= 617;
                break;
            case 2628:
                x[i] ^= 2538;
                break;
            case 2629:
                x[i] ^= 3207;
                break;
            case 2630:
                x[i] ^= 3842;
                break;
            case 2631:
                x[i] ^= 311;
                break;
            case 2632:
                x[i] ^= 2126;
                break;
            case 2633:
                x[i] ^= 3004;
                break;
            case 2634:
                x[i] ^= 2980;
                break;
            case 2635:
                x[i] ^= 2576;
                break;
            case 2636:
                x[i] ^= 2536;
                break;
            case 2637:
                x[i] ^= 1418;
                break;
            case 2638:
                x[i] ^= 3549;
                break;
            case 2639:
                x[i] ^= 3328;
                break;
            case 2640:
                x[i] ^= 1826;
                break;
            case 2641:
                x[i] ^= 654;
                break;
            case 2642:
                x[i] ^= 1738;
                break;
            case 2643:
                x[i] ^= 1457;
                break;
            case 2644:
                x[i] ^= 3915;
                break;
            case 2645:
                x[i] ^= 46;
                break;
            case 2646:
                x[i] ^= 818;
                break;
            case 2647:
                x[i] ^= 3385;
                break;
            case 2648:
                x[i] ^= 1096;
                break;
            case 2649:
                x[i] ^= 2107;
                break;
            case 2650:
                x[i] ^= 62;
                break;
            case 2651:
                x[i] ^= 958;
                break;
            case 2652:
                x[i] ^= 4015;
                break;
            case 2653:
                x[i] ^= 2341;
                break;
            case 2654:
                x[i] ^= 1853;
                break;
            case 2655:
                x[i] ^= 202;
                break;
            case 2656:
                x[i] ^= 2997;
                break;
            case 2657:
                x[i] ^= 2369;
                break;
            case 2658:
                x[i] ^= 650;
                break;
            case 2659:
                x[i] ^= 1922;
                break;
            case 2660:
                x[i] ^= 1619;
                break;
            case 2661:
                x[i] ^= 3647;
                break;
            case 2662:
                x[i] ^= 3504;
                break;
            case 2663:
                x[i] ^= 1113;
                break;
            case 2664:
                x[i] ^= 1437;
                break;
            case 2665:
                x[i] ^= 2992;
                break;
            case 2666:
                x[i] ^= 2398;
                break;
            case 2667:
                x[i] ^= 1012;
                break;
            case 2668:
                x[i] ^= 3255;
                break;
            case 2669:
                x[i] ^= 381;
                break;
            case 2670:
                x[i] ^= 3782;
                break;
            case 2671:
                x[i] ^= 3746;
                break;
            case 2672:
                x[i] ^= 2753;
                break;
            case 2673:
                x[i] ^= 3835;
                break;
            case 2674:
                x[i] ^= 3734;
                break;
            case 2675:
                x[i] ^= 3969;
                break;
            case 2676:
                x[i] ^= 1795;
                break;
            case 2677:
                x[i] ^= 3981;
                break;
            case 2678:
                x[i] ^= 1486;
                break;
            case 2679:
                x[i] ^= 728;
                break;
            case 2680:
                x[i] ^= 1739;
                break;
            case 2681:
                x[i] ^= 2123;
                break;
            case 2682:
                x[i] ^= 2937;
                break;
            case 2683:
                x[i] ^= 2410;
                break;
            case 2684:
                x[i] ^= 1837;
                break;
            case 2685:
                x[i] ^= 1231;
                break;
            case 2686:
                x[i] ^= 1314;
                break;
            case 2687:
                x[i] ^= 2840;
                break;
            case 2688:
                x[i] ^= 3456;
                break;
            case 2689:
                x[i] ^= 391;
                break;
            case 2690:
                x[i] ^= 2975;
                break;
            case 2691:
                x[i] ^= 573;
                break;
            case 2692:
                x[i] ^= 128;
                break;
            case 2693:
                x[i] ^= 1453;
                break;
            case 2694:
                x[i] ^= 1512;
                break;
            case 2695:
                x[i] ^= 93;
                break;
            case 2696:
                x[i] ^= 1151;
                break;
            case 2697:
                x[i] ^= 2689;
                break;
            case 2698:
                x[i] ^= 3444;
                break;
            case 2699:
                x[i] ^= 3377;
                break;
            case 2700:
                x[i] ^= 2316;
                break;
            case 2701:
                x[i] ^= 3475;
                break;
            case 2702:
                x[i] ^= 718;
                break;
            case 2703:
                x[i] ^= 2259;
                break;
            case 2704:
                x[i] ^= 3101;
                break;
            case 2705:
                x[i] ^= 424;
                break;
            case 2706:
                x[i] ^= 3233;
                break;
            case 2707:
                x[i] ^= 1815;
                break;
            case 2708:
                x[i] ^= 4022;
                break;
            case 2709:
                x[i] ^= 3857;
                break;
            case 2710:
                x[i] ^= 1251;
                break;
            case 2711:
                x[i] ^= 401;
                break;
            case 2712:
                x[i] ^= 3243;
                break;
            case 2713:
                x[i] ^= 857;
                break;
            case 2714:
                x[i] ^= 3910;
                break;
            case 2715:
                x[i] ^= 1590;
                break;
            case 2716:
                x[i] ^= 1357;
                break;
            case 2717:
                x[i] ^= 3463;
                break;
            case 2718:
                x[i] ^= 2167;
                break;
            case 2719:
                x[i] ^= 1667;
                break;
            case 2720:
                x[i] ^= 1205;
                break;
            case 2721:
                x[i] ^= 3225;
                break;
            case 2722:
                x[i] ^= 2808;
                break;
            case 2723:
                x[i] ^= 665;
                break;
            case 2724:
                x[i] ^= 1519;
                break;
            case 2725:
                x[i] ^= 885;
                break;
            case 2726:
                x[i] ^= 76;
                break;
            case 2727:
                x[i] ^= 687;
                break;
            case 2728:
                x[i] ^= 551;
                break;
            case 2729:
                x[i] ^= 2672;
                break;
            case 2730:
                x[i] ^= 1858;
                break;
            case 2731:
                x[i] ^= 3577;
                break;
            case 2732:
                x[i] ^= 4068;
                break;
            case 2733:
                x[i] ^= 1305;
                break;
            case 2734:
                x[i] ^= 1353;
                break;
            case 2735:
                x[i] ^= 1655;
                break;
            case 2736:
                x[i] ^= 3027;
                break;
            case 2737:
                x[i] ^= 1355;
                break;
            case 2738:
                x[i] ^= 3792;
                break;
            case 2739:
                x[i] ^= 3810;
                break;
            case 2740:
                x[i] ^= 4005;
                break;
            case 2741:
                x[i] ^= 3001;
                break;
            case 2742:
                x[i] ^= 40;
                break;
            case 2743:
                x[i] ^= 808;
                break;
            case 2744:
                x[i] ^= 1845;
                break;
            case 2745:
                x[i] ^= 3282;
                break;
            case 2746:
                x[i] ^= 1788;
                break;
            case 2747:
                x[i] ^= 3614;
                break;
            case 2748:
                x[i] ^= 61;
                break;
            case 2749:
                x[i] ^= 3572;
                break;
            case 2750:
                x[i] ^= 3129;
                break;
            case 2751:
                x[i] ^= 1666;
                break;
            case 2752:
                x[i] ^= 3426;
                break;
            case 2753:
                x[i] ^= 3611;
                break;
            case 2754:
                x[i] ^= 2233;
                break;
            case 2755:
                x[i] ^= 3927;
                break;
            case 2756:
                x[i] ^= 2569;
                break;
            case 2757:
                x[i] ^= 1703;
                break;
            case 2758:
                x[i] ^= 3352;
                break;
            case 2759:
                x[i] ^= 298;
                break;
            case 2760:
                x[i] ^= 1094;
                break;
            case 2761:
                x[i] ^= 343;
                break;
            case 2762:
                x[i] ^= 2443;
                break;
            case 2763:
                x[i] ^= 769;
                break;
            case 2764:
                x[i] ^= 1804;
                break;
            case 2765:
                x[i] ^= 2353;
                break;
            case 2766:
                x[i] ^= 2392;
                break;
            case 2767:
                x[i] ^= 2417;
                break;
            case 2768:
                x[i] ^= 2023;
                break;
            case 2769:
                x[i] ^= 2670;
                break;
            case 2770:
                x[i] ^= 1323;
                break;
            case 2771:
                x[i] ^= 467;
                break;
            case 2772:
                x[i] ^= 3801;
                break;
            case 2773:
                x[i] ^= 1782;
                break;
            case 2774:
                x[i] ^= 3087;
                break;
            case 2775:
                x[i] ^= 3674;
                break;
            case 2776:
                x[i] ^= 1756;
                break;
            case 2777:
                x[i] ^= 1737;
                break;
            case 2778:
                x[i] ^= 2710;
                break;
            case 2779:
                x[i] ^= 1908;
                break;
            case 2780:
                x[i] ^= 2319;
                break;
            case 2781:
                x[i] ^= 1383;
                break;
            case 2782:
                x[i] ^= 3625;
                break;
            case 2783:
                x[i] ^= 1051;
                break;
            case 2784:
                x[i] ^= 1193;
                break;
            case 2785:
                x[i] ^= 151;
                break;
            case 2786:
                x[i] ^= 1792;
                break;
            case 2787:
                x[i] ^= 3065;
                break;
            case 2788:
                x[i] ^= 2545;
                break;
            case 2789:
                x[i] ^= 1876;
                break;
            case 2790:
                x[i] ^= 1776;
                break;
            case 2791:
                x[i] ^= 1934;
                break;
            case 2792:
                x[i] ^= 3058;
                break;
            case 2793:
                x[i] ^= 2257;
                break;
            case 2794:
                x[i] ^= 2333;
                break;
            case 2795:
                x[i] ^= 2356;
                break;
            case 2796:
                x[i] ^= 413;
                break;
            case 2797:
                x[i] ^= 3021;
                break;
            case 2798:
                x[i] ^= 29;
                break;
            case 2799:
                x[i] ^= 2325;
                break;
            case 2800:
                x[i] ^= 727;
                break;
            case 2801:
                x[i] ^= 2331;
                break;
            case 2802:
                x[i] ^= 317;
                break;
            case 2803:
                x[i] ^= 1518;
                break;
            case 2804:
                x[i] ^= 565;
                break;
            case 2805:
                x[i] ^= 921;
                break;
            case 2806:
                x[i] ^= 2192;
                break;
            case 2807:
                x[i] ^= 1573;
                break;
            case 2808:
                x[i] ^= 2971;
                break;
            case 2809:
                x[i] ^= 1866;
                break;
            case 2810:
                x[i] ^= 4053;
                break;
            case 2811:
                x[i] ^= 478;
                break;
            case 2812:
                x[i] ^= 3043;
                break;
            case 2813:
                x[i] ^= 1152;
                break;
            case 2814:
                x[i] ^= 1078;
                break;
            case 2815:
                x[i] ^= 867;
                break;
            case 2816:
                x[i] ^= 1758;
                break;
            case 2817:
                x[i] ^= 3587;
                break;
            case 2818:
                x[i] ^= 2041;
                break;
            case 2819:
                x[i] ^= 3064;
                break;
            case 2820:
                x[i] ^= 3306;
                break;
            case 2821:
                x[i] ^= 131;
                break;
            case 2822:
                x[i] ^= 1553;
                break;
            case 2823:
                x[i] ^= 4032;
                break;
            case 2824:
                x[i] ^= 3941;
                break;
            case 2825:
                x[i] ^= 241;
                break;
            case 2826:
                x[i] ^= 1214;
                break;
            case 2827:
                x[i] ^= 2732;
                break;
            case 2828:
                x[i] ^= 923;
                break;
            case 2829:
                x[i] ^= 2145;
                break;
            case 2830:
                x[i] ^= 2712;
                break;
            case 2831:
                x[i] ^= 1176;
                break;
            case 2832:
                x[i] ^= 2208;
                break;
            case 2833:
                x[i] ^= 1173;
                break;
            case 2834:
                x[i] ^= 3000;
                break;
            case 2835:
                x[i] ^= 3300;
                break;
            case 2836:
                x[i] ^= 1014;
                break;
            case 2837:
                x[i] ^= 2468;
                break;
            case 2838:
                x[i] ^= 410;
                break;
            case 2839:
                x[i] ^= 1181;
                break;
            case 2840:
                x[i] ^= 1749;
                break;
            case 2841:
                x[i] ^= 2547;
                break;
            case 2842:
                x[i] ^= 3460;
                break;
            case 2843:
                x[i] ^= 2828;
                break;
            case 2844:
                x[i] ^= 3105;
                break;
            case 2845:
                x[i] ^= 66;
                break;
            case 2846:
                x[i] ^= 1419;
                break;
            case 2847:
                x[i] ^= 641;
                break;
            case 2848:
                x[i] ^= 2550;
                break;
            case 2849:
                x[i] ^= 2570;
                break;
            case 2850:
                x[i] ^= 2585;
                break;
            case 2851:
                x[i] ^= 483;
                break;
            case 2852:
                x[i] ^= 1462;
                break;
            case 2853:
                x[i] ^= 1527;
                break;
            case 2854:
                x[i] ^= 2168;
                break;
            case 2855:
                x[i] ^= 3701;
                break;
            case 2856:
                x[i] ^= 675;
                break;
            case 2857:
                x[i] ^= 2128;
                break;
            case 2858:
                x[i] ^= 3424;
                break;
            case 2859:
                x[i] ^= 1805;
                break;
            case 2860:
                x[i] ^= 1721;
                break;
            case 2861:
                x[i] ^= 623;
                break;
            case 2862:
                x[i] ^= 3909;
                break;
            case 2863:
                x[i] ^= 3760;
                break;
            case 2864:
                x[i] ^= 1817;
                break;
            case 2865:
                x[i] ^= 473;
                break;
            case 2866:
                x[i] ^= 366;
                break;
            case 2867:
                x[i] ^= 562;
                break;
            case 2868:
                x[i] ^= 2195;
                break;
            case 2869:
                x[i] ^= 706;
                break;
            case 2870:
                x[i] ^= 273;
                break;
            case 2871:
                x[i] ^= 673;
                break;
            case 2872:
                x[i] ^= 262;
                break;
            case 2873:
                x[i] ^= 2053;
                break;
            case 2874:
                x[i] ^= 4077;
                break;
            case 2875:
                x[i] ^= 1583;
                break;
            case 2876:
                x[i] ^= 3337;
                break;
            case 2877:
                x[i] ^= 1892;
                break;
            case 2878:
                x[i] ^= 2186;
                break;
            case 2879:
                x[i] ^= 2028;
                break;
            case 2880:
                x[i] ^= 2432;
                break;
            case 2881:
                x[i] ^= 572;
                break;
            case 2882:
                x[i] ^= 2635;
                break;
            case 2883:
                x[i] ^= 1940;
                break;
            case 2884:
                x[i] ^= 595;
                break;
            case 2885:
                x[i] ^= 2011;
                break;
            case 2886:
                x[i] ^= 739;
                break;
            case 2887:
                x[i] ^= 2349;
                break;
            case 2888:
                x[i] ^= 1636;
                break;
            case 2889:
                x[i] ^= 3309;
                break;
            case 2890:
                x[i] ^= 152;
                break;
            case 2891:
                x[i] ^= 481;
                break;
            case 2892:
                x[i] ^= 1002;
                break;
            case 2893:
                x[i] ^= 3686;
                break;
            case 2894:
                x[i] ^= 1112;
                break;
            case 2895:
                x[i] ^= 3714;
                break;
            case 2896:
                x[i] ^= 1491;
                break;
            case 2897:
                x[i] ^= 3673;
                break;
            case 2898:
                x[i] ^= 3174;
                break;
            case 2899:
                x[i] ^= 3245;
                break;
            case 2900:
                x[i] ^= 2610;
                break;
            case 2901:
                x[i] ^= 2189;
                break;
            case 2902:
                x[i] ^= 94;
                break;
            case 2903:
                x[i] ^= 1877;
                break;
            case 2904:
                x[i] ^= 1649;
                break;
            case 2905:
                x[i] ^= 2799;
                break;
            case 2906:
                x[i] ^= 2873;
                break;
            case 2907:
                x[i] ^= 3506;
                break;
            case 2908:
                x[i] ^= 2899;
                break;
            case 2909:
                x[i] ^= 861;
                break;
            case 2910:
                x[i] ^= 3280;
                break;
            case 2911:
                x[i] ^= 4038;
                break;
            case 2912:
                x[i] ^= 3995;
                break;
            case 2913:
                x[i] ^= 250;
                break;
            case 2914:
                x[i] ^= 463;
                break;
            case 2915:
                x[i] ^= 3173;
                break;
            case 2916:
                x[i] ^= 2206;
                break;
            case 2917:
                x[i] ^= 3851;
                break;
            case 2918:
                x[i] ^= 3343;
                break;
            case 2919:
                x[i] ^= 931;
                break;
            case 2920:
                x[i] ^= 1560;
                break;
            case 2921:
                x[i] ^= 2713;
                break;
            case 2922:
                x[i] ^= 3449;
                break;
            case 2923:
                x[i] ^= 3281;
                break;
            case 2924:
                x[i] ^= 614;
                break;
            case 2925:
                x[i] ^= 1995;
                break;
            case 2926:
                x[i] ^= 2270;
                break;
            case 2927:
                x[i] ^= 2381;
                break;
            case 2928:
                x[i] ^= 3019;
                break;
            case 2929:
                x[i] ^= 3532;
                break;
            case 2930:
                x[i] ^= 1793;
                break;
            case 2931:
                x[i] ^= 3671;
                break;
            case 2932:
                x[i] ^= 1118;
                break;
            case 2933:
                x[i] ^= 3139;
                break;
            case 2934:
                x[i] ^= 42;
                break;
            case 2935:
                x[i] ^= 1849;
                break;
            case 2936:
                x[i] ^= 1951;
                break;
            case 2937:
                x[i] ^= 2065;
                break;
            case 2938:
                x[i] ^= 3916;
                break;
            case 2939:
                x[i] ^= 1364;
                break;
            case 2940:
                x[i] ^= 2357;
                break;
            case 2941:
                x[i] ^= 482;
                break;
            case 2942:
                x[i] ^= 2921;
                break;
            case 2943:
                x[i] ^= 14;
                break;
            case 2944:
                x[i] ^= 2165;
                break;
            case 2945:
                x[i] ^= 526;
                break;
            case 2946:
                x[i] ^= 1952;
                break;
            case 2947:
                x[i] ^= 465;
                break;
            case 2948:
                x[i] ^= 2104;
                break;
            case 2949:
                x[i] ^= 2905;
                break;
            case 2950:
                x[i] ^= 3685;
                break;
            case 2951:
                x[i] ^= 177;
                break;
            case 2952:
                x[i] ^= 2482;
                break;
            case 2953:
                x[i] ^= 3948;
                break;
            case 2954:
                x[i] ^= 3146;
                break;
            case 2955:
                x[i] ^= 1179;
                break;
            case 2956:
                x[i] ^= 1434;
                break;
            case 2957:
                x[i] ^= 1121;
                break;
            case 2958:
                x[i] ^= 2089;
                break;
            case 2959:
                x[i] ^= 2223;
                break;
            case 2960:
                x[i] ^= 1295;
                break;
            case 2961:
                x[i] ^= 3974;
                break;
            case 2962:
                x[i] ^= 2245;
                break;
            case 2963:
                x[i] ^= 2078;
                break;
            case 2964:
                x[i] ^= 3420;
                break;
            case 2965:
                x[i] ^= 2861;
                break;
            case 2966:
                x[i] ^= 1477;
                break;
            case 2967:
                x[i] ^= 1689;
                break;
            case 2968:
                x[i] ^= 2204;
                break;
            case 2969:
                x[i] ^= 134;
                break;
            case 2970:
                x[i] ^= 930;
                break;
            case 2971:
                x[i] ^= 17;
                break;
            case 2972:
                x[i] ^= 3091;
                break;
            case 2973:
                x[i] ^= 324;
                break;
            case 2974:
                x[i] ^= 3645;
                break;
            case 2975:
                x[i] ^= 712;
                break;
            case 2976:
                x[i] ^= 1490;
                break;
            case 2977:
                x[i] ^= 223;
                break;
            case 2978:
                x[i] ^= 3874;
                break;
            case 2979:
                x[i] ^= 4078;
                break;
            case 2980:
                x[i] ^= 2734;
                break;
            case 2981:
                x[i] ^= 896;
                break;
            case 2982:
                x[i] ^= 3712;
                break;
            case 2983:
                x[i] ^= 1984;
                break;
            case 2984:
                x[i] ^= 3055;
                break;
            case 2985:
                x[i] ^= 1101;
                break;
            case 2986:
                x[i] ^= 2169;
                break;
            case 2987:
                x[i] ^= 2757;
                break;
            case 2988:
                x[i] ^= 3566;
                break;
            case 2989:
                x[i] ^= 1874;
                break;
            case 2990:
                x[i] ^= 3082;
                break;
            case 2991:
                x[i] ^= 3184;
                break;
            case 2992:
                x[i] ^= 1378;
                break;
            case 2993:
                x[i] ^= 3335;
                break;
            case 2994:
                x[i] ^= 3227;
                break;
            case 2995:
                x[i] ^= 3516;
                break;
            case 2996:
                x[i] ^= 510;
                break;
            case 2997:
                x[i] ^= 1635;
                break;
            case 2998:
                x[i] ^= 2240;
                break;
            case 2999:
                x[i] ^= 3967;
                break;
            case 3000:
                x[i] ^= 232;
                break;
            case 3001:
                x[i] ^= 3750;
                break;
            case 3002:
                x[i] ^= 1403;
                break;
            case 3003:
                x[i] ^= 1610;
                break;
            case 3004:
                x[i] ^= 3728;
                break;
            case 3005:
                x[i] ^= 3930;
                break;
            case 3006:
                x[i] ^= 148;
                break;
            case 3007:
                x[i] ^= 1466;
                break;
            case 3008:
                x[i] ^= 1830;
                break;
            case 3009:
                x[i] ^= 1507;
                break;
            case 3010:
                x[i] ^= 3944;
                break;
            case 3011:
                x[i] ^= 590;
                break;
            case 3012:
                x[i] ^= 3297;
                break;
            case 3013:
                x[i] ^= 3090;
                break;
            case 3014:
                x[i] ^= 549;
                break;
            case 3015:
                x[i] ^= 514;
                break;
            case 3016:
                x[i] ^= 3482;
                break;
            case 3017:
                x[i] ^= 1;
                break;
            case 3018:
                x[i] ^= 3757;
                break;
            case 3019:
                x[i] ^= 28;
                break;
            case 3020:
                x[i] ^= 1425;
                break;
            case 3021:
                x[i] ^= 390;
                break;
            case 3022:
                x[i] ^= 1606;
                break;
            case 3023:
                x[i] ^= 2530;
                break;
            case 3024:
                x[i] ^= 2528;
                break;
            case 3025:
                x[i] ^= 556;
                break;
            case 3026:
                x[i] ^= 3500;
                break;
            case 3027:
                x[i] ^= 2140;
                break;
            case 3028:
                x[i] ^= 3408;
                break;
            case 3029:
                x[i] ^= 2620;
                break;
            case 3030:
                x[i] ^= 1385;
                break;
            case 3031:
                x[i] ^= 3023;
                break;
            case 3032:
                x[i] ^= 906;
                break;
            case 3033:
                x[i] ^= 1911;
                break;
            case 3034:
                x[i] ^= 3256;
                break;
            case 3035:
                x[i] ^= 2973;
                break;
            case 3036:
                x[i] ^= 2826;
                break;
            case 3037:
                x[i] ^= 3013;
                break;
            case 3038:
                x[i] ^= 2531;
                break;
            case 3039:
                x[i] ^= 3805;
                break;
            case 3040:
                x[i] ^= 388;
                break;
            case 3041:
                x[i] ^= 380;
                break;
            case 3042:
                x[i] ^= 3026;
                break;
            case 3043:
                x[i] ^= 304;
                break;
            case 3044:
                x[i] ^= 2744;
                break;
            case 3045:
                x[i] ^= 3195;
                break;
            case 3046:
                x[i] ^= 1394;
                break;
            case 3047:
                x[i] ^= 2300;
                break;
            case 3048:
                x[i] ^= 3381;
                break;
            case 3049:
                x[i] ^= 522;
                break;
            case 3050:
                x[i] ^= 1770;
                break;
            case 3051:
                x[i] ^= 3290;
                break;
            case 3052:
                x[i] ^= 1660;
                break;
            case 3053:
                x[i] ^= 3284;
                break;
            case 3054:
                x[i] ^= 2363;
                break;
            case 3055:
                x[i] ^= 3387;
                break;
            case 3056:
                x[i] ^= 1286;
                break;
            case 3057:
                x[i] ^= 507;
                break;
            case 3058:
                x[i] ^= 2787;
                break;
            case 3059:
                x[i] ^= 3601;
                break;
            case 3060:
                x[i] ^= 1129;
                break;
            case 3061:
                x[i] ^= 3487;
                break;
            case 3062:
                x[i] ^= 2625;
                break;
            case 3063:
                x[i] ^= 1617;
                break;
            case 3064:
                x[i] ^= 668;
                break;
            case 3065:
                x[i] ^= 3830;
                break;
            case 3066:
                x[i] ^= 3555;
                break;
            case 3067:
                x[i] ^= 2864;
                break;
            case 3068:
                x[i] ^= 1890;
                break;
            case 3069:
                x[i] ^= 3359;
                break;
            case 3070:
                x[i] ^= 1007;
                break;
            case 3071:
                x[i] ^= 360;
                break;
            case 3072:
                x[i] ^= 2228;
                break;
            case 3073:
                x[i] ^= 221;
                break;
            case 3074:
                x[i] ^= 1326;
                break;
            case 3075:
                x[i] ^= 3621;
                break;
            case 3076:
                x[i] ^= 1253;
                break;
            case 3077:
                x[i] ^= 2529;
                break;
            case 3078:
                x[i] ^= 2070;
                break;
            case 3079:
                x[i] ^= 208;
                break;
            case 3080:
                x[i] ^= 389;
                break;
            case 3081:
                x[i] ^= 2802;
                break;
            case 3082:
                x[i] ^= 183;
                break;
            case 3083:
                x[i] ^= 3458;
                break;
            case 3084:
                x[i] ^= 2609;
                break;
            case 3085:
                x[i] ^= 2116;
                break;
            case 3086:
                x[i] ^= 3039;
                break;
            case 3087:
                x[i] ^= 3461;
                break;
            case 3088:
                x[i] ^= 2822;
                break;
            case 3089:
                x[i] ^= 1081;
                break;
            case 3090:
                x[i] ^= 3320;
                break;
            case 3091:
                x[i] ^= 520;
                break;
            case 3092:
                x[i] ^= 3979;
                break;
            case 3093:
                x[i] ^= 3167;
                break;
            case 3094:
                x[i] ^= 3547;
                break;
            case 3095:
                x[i] ^= 1868;
                break;
            case 3096:
                x[i] ^= 2359;
                break;
            case 3097:
                x[i] ^= 125;
                break;
            case 3098:
                x[i] ^= 1835;
                break;
            case 3099:
                x[i] ^= 1343;
                break;
            case 3100:
                x[i] ^= 2278;
                break;
            case 3101:
                x[i] ^= 1764;
                break;
            case 3102:
                x[i] ^= 988;
                break;
            case 3103:
                x[i] ^= 3086;
                break;
            case 3104:
                x[i] ^= 1678;
                break;
            case 3105:
                x[i] ^= 2772;
                break;
            case 3106:
                x[i] ^= 742;
                break;
            case 3107:
                x[i] ^= 2122;
                break;
            case 3108:
                x[i] ^= 169;
                break;
            case 3109:
                x[i] ^= 3323;
                break;
            case 3110:
                x[i] ^= 1559;
                break;
            case 3111:
                x[i] ^= 707;
                break;
            case 3112:
                x[i] ^= 102;
                break;
            case 3113:
                x[i] ^= 2638;
                break;
            case 3114:
                x[i] ^= 3567;
                break;
            case 3115:
                x[i] ^= 1087;
                break;
            case 3116:
                x[i] ^= 1698;
                break;
            case 3117:
                x[i] ^= 3120;
                break;
            case 3118:
                x[i] ^= 326;
                break;
            case 3119:
                x[i] ^= 3661;
                break;
            case 3120:
                x[i] ^= 3703;
                break;
            case 3121:
                x[i] ^= 626;
                break;
            case 3122:
                x[i] ^= 47;
                break;
            case 3123:
                x[i] ^= 3287;
                break;
            case 3124:
                x[i] ^= 1638;
                break;
            case 3125:
                x[i] ^= 3040;
                break;
            case 3126:
                x[i] ^= 1688;
                break;
            case 3127:
                x[i] ^= 2106;
                break;
            case 3128:
                x[i] ^= 3276;
                break;
            case 3129:
                x[i] ^= 1800;
                break;
            case 3130:
                x[i] ^= 1881;
                break;
            case 3131:
                x[i] ^= 69;
                break;
            case 3132:
                x[i] ^= 1098;
                break;
            case 3133:
                x[i] ^= 3620;
                break;
            case 3134:
                x[i] ^= 3059;
                break;
            case 3135:
                x[i] ^= 1482;
                break;
            case 3136:
                x[i] ^= 3633;
                break;
            case 3137:
                x[i] ^= 1918;
                break;
            case 3138:
                x[i] ^= 3211;
                break;
            case 3139:
                x[i] ^= 114;
                break;
            case 3140:
                x[i] ^= 1980;
                break;
            case 3141:
                x[i] ^= 592;
                break;
            case 3142:
                x[i] ^= 786;
                break;
            case 3143:
                x[i] ^= 2657;
                break;
            case 3144:
                x[i] ^= 778;
                break;
            case 3145:
                x[i] ^= 946;
                break;
            case 3146:
                x[i] ^= 363;
                break;
            case 3147:
                x[i] ^= 3589;
                break;
            case 3148:
                x[i] ^= 1209;
                break;
            case 3149:
                x[i] ^= 1759;
                break;
            case 3150:
                x[i] ^= 477;
                break;
            case 3151:
                x[i] ^= 662;
                break;
            case 3152:
                x[i] ^= 2347;
                break;
            case 3153:
                x[i] ^= 2733;
                break;
            case 3154:
                x[i] ^= 1420;
                break;
            case 3155:
                x[i] ^= 608;
                break;
            case 3156:
                x[i] ^= 428;
                break;
            case 3157:
                x[i] ^= 3769;
                break;
            case 3158:
                x[i] ^= 4026;
                break;
            case 3159:
                x[i] ^= 3029;
                break;
            case 3160:
                x[i] ^= 1801;
                break;
            case 3161:
                x[i] ^= 2812;
                break;
            case 3162:
                x[i] ^= 1182;
                break;
            case 3163:
                x[i] ^= 1783;
                break;
            case 3164:
                x[i] ^= 1057;
                break;
            case 3165:
                x[i] ^= 392;
                break;
            case 3166:
                x[i] ^= 3638;
                break;
            case 3167:
                x[i] ^= 2101;
                break;
            case 3168:
                x[i] ^= 2311;
                break;
            case 3169:
                x[i] ^= 3099;
                break;
            case 3170:
                x[i] ^= 2431;
                break;
            case 3171:
                x[i] ^= 598;
                break;
            case 3172:
                x[i] ^= 1554;
                break;
            case 3173:
                x[i] ^= 328;
                break;
            case 3174:
                x[i] ^= 3304;
                break;
            case 3175:
                x[i] ^= 2100;
                break;
            case 3176:
                x[i] ^= 126;
                break;
            case 3177:
                x[i] ^= 2903;
                break;
            case 3178:
                x[i] ^= 2872;
                break;
            case 3179:
                x[i] ^= 2782;
                break;
            case 3180:
                x[i] ^= 693;
                break;
            case 3181:
                x[i] ^= 2676;
                break;
            case 3182:
                x[i] ^= 3509;
                break;
            case 3183:
                x[i] ^= 3606;
                break;
            case 3184:
                x[i] ^= 2511;
                break;
            case 3185:
                x[i] ^= 4028;
                break;
            case 3186:
                x[i] ^= 3125;
                break;
            case 3187:
                x[i] ^= 719;
                break;
            case 3188:
                x[i] ^= 1947;
                break;
            case 3189:
                x[i] ^= 1198;
                break;
            case 3190:
                x[i] ^= 3119;
                break;
            case 3191:
                x[i] ^= 3501;
                break;
            case 3192:
                x[i] ^= 3715;
                break;
            case 3193:
                x[i] ^= 236;
                break;
            case 3194:
                x[i] ^= 2945;
                break;
            case 3195:
                x[i] ^= 3156;
                break;
            case 3196:
                x[i] ^= 1930;
                break;
            case 3197:
                x[i] ^= 3230;
                break;
            case 3198:
                x[i] ^= 2981;
                break;
            case 3199:
                x[i] ^= 1614;
                break;
            case 3200:
                x[i] ^= 2380;
                break;
            case 3201:
                x[i] ^= 89;
                break;
            case 3202:
                x[i] ^= 197;
                break;
            case 3203:
                x[i] ^= 2379;
                break;
            case 3204:
                x[i] ^= 3678;
                break;
            case 3205:
                x[i] ^= 2629;
                break;
            case 3206:
                x[i] ^= 3939;
                break;
            case 3207:
                x[i] ^= 445;
                break;
            case 3208:
                x[i] ^= 2557;
                break;
            case 3209:
                x[i] ^= 3176;
                break;
            case 3210:
                x[i] ^= 1939;
                break;
            case 3211:
                x[i] ^= 756;
                break;
            case 3212:
                x[i] ^= 2494;
                break;
            case 3213:
                x[i] ^= 2679;
                break;
            case 3214:
                x[i] ^= 681;
                break;
            case 3215:
                x[i] ^= 1921;
                break;
            case 3216:
                x[i] ^= 1990;
                break;
            case 3217:
                x[i] ^= 754;
                break;
            case 3218:
                x[i] ^= 2544;
                break;
            case 3219:
                x[i] ^= 793;
                break;
            case 3220:
                x[i] ^= 3263;
                break;
            case 3221:
                x[i] ^= 2473;
                break;
            case 3222:
                x[i] ^= 50;
                break;
            case 3223:
                x[i] ^= 864;
                break;
            case 3224:
                x[i] ^= 3025;
                break;
            case 3225:
                x[i] ^= 1594;
                break;
            case 3226:
                x[i] ^= 842;
                break;
            case 3227:
                x[i] ^= 2807;
                break;
            case 3228:
                x[i] ^= 1882;
                break;
            case 3229:
                x[i] ^= 3585;
                break;
            case 3230:
                x[i] ^= 249;
                break;
            case 3231:
                x[i] ^= 365;
                break;
            case 3232:
                x[i] ^= 965;
                break;
            case 3233:
                x[i] ^= 1942;
                break;
            case 3234:
                x[i] ^= 2587;
                break;
            case 3235:
                x[i] ^= 1904;
                break;
            case 3236:
                x[i] ^= 1633;
                break;
            case 3237:
                x[i] ^= 1577;
                break;
            case 3238:
                x[i] ^= 2829;
                break;
            case 3239:
                x[i] ^= 1859;
                break;
            case 3240:
                x[i] ^= 3580;
                break;
            case 3241:
                x[i] ^= 3756;
                break;
            case 3242:
                x[i] ^= 367;
                break;
            case 3243:
                x[i] ^= 2059;
                break;
            case 3244:
                x[i] ^= 96;
                break;
            case 3245:
                x[i] ^= 3010;
                break;
            case 3246:
                x[i] ^= 1733;
                break;
            case 3247:
                x[i] ^= 1681;
                break;
            case 3248:
                x[i] ^= 2603;
                break;
            case 3249:
                x[i] ^= 644;
                break;
            case 3250:
                x[i] ^= 3722;
                break;
            case 3251:
                x[i] ^= 3095;
                break;
            case 3252:
                x[i] ^= 3118;
                break;
            case 3253:
                x[i] ^= 2810;
                break;
            case 3254:
                x[i] ^= 1846;
                break;
            case 3255:
                x[i] ^= 799;
                break;
            case 3256:
                x[i] ^= 3494;
                break;
            case 3257:
                x[i] ^= 1356;
                break;
            case 3258:
                x[i] ^= 2112;
                break;
            case 3259:
                x[i] ^= 1854;
                break;
            case 3260:
                x[i] ^= 1850;
                break;
            case 3261:
                x[i] ^= 1992;
                break;
            case 3262:
                x[i] ^= 3136;
                break;
            case 3263:
                x[i] ^= 2520;
                break;
            case 3264:
                x[i] ^= 2085;
                break;
            case 3265:
                x[i] ^= 1855;
                break;
            case 3266:
                x[i] ^= 3160;
                break;
            case 3267:
                x[i] ^= 1711;
                break;
            case 3268:
                x[i] ^= 1254;
                break;
            case 3269:
                x[i] ^= 1028;
                break;
            case 3270:
                x[i] ^= 3559;
                break;
            case 3271:
                x[i] ^= 431;
                break;
            case 3272:
                x[i] ^= 3380;
                break;
            case 3273:
                x[i] ^= 2110;
                break;
            case 3274:
                x[i] ^= 2875;
                break;
            case 3275:
                x[i] ^= 2986;
                break;
            case 3276:
                x[i] ^= 1516;
                break;
            case 3277:
                x[i] ^= 3036;
                break;
            case 3278:
                x[i] ^= 1825;
                break;
            case 3279:
                x[i] ^= 2957;
                break;
            case 3280:
                x[i] ^= 3986;
                break;
            case 3281:
                x[i] ^= 2057;
                break;
            case 3282:
                x[i] ^= 3649;
                break;
            case 3283:
                x[i] ^= 74;
                break;
            case 3284:
                x[i] ^= 1321;
                break;
            case 3285:
                x[i] ^= 852;
                break;
            case 3286:
                x[i] ^= 2558;
                break;
            case 3287:
                x[i] ^= 2642;
                break;
            case 3288:
                x[i] ^= 179;
                break;
            case 3289:
                x[i] ^= 1269;
                break;
            case 3290:
                x[i] ^= 1970;
                break;
            case 3291:
                x[i] ^= 550;
                break;
            case 3292:
                x[i] ^= 3806;
                break;
            case 3293:
                x[i] ^= 1102;
                break;
            case 3294:
                x[i] ^= 579;
                break;
            case 3295:
                x[i] ^= 2109;
                break;
            case 3296:
                x[i] ^= 1613;
                break;
            case 3297:
                x[i] ^= 744;
                break;
            case 3298:
                x[i] ^= 3953;
                break;
            case 3299:
                x[i] ^= 1413;
                break;
            case 3300:
                x[i] ^= 3438;
                break;
            case 3301:
                x[i] ^= 1292;
                break;
            case 3302:
                x[i] ^= 216;
                break;
            case 3303:
                x[i] ^= 3799;
                break;
            case 3304:
                x[i] ^= 1293;
                break;
            case 3305:
                x[i] ^= 2061;
                break;
            case 3306:
                x[i] ^= 3486;
                break;
            case 3307:
                x[i] ^= 542;
                break;
            case 3308:
                x[i] ^= 3897;
                break;
            case 3309:
                x[i] ^= 932;
                break;
            case 3310:
                x[i] ^= 2088;
                break;
            case 3311:
                x[i] ^= 2485;
                break;
            case 3312:
                x[i] ^= 1761;
                break;
            case 3313:
                x[i] ^= 1120;
                break;
            case 3314:
                x[i] ^= 1810;
                break;
            case 3315:
                x[i] ^= 3831;
                break;
            case 3316:
                x[i] ^= 1629;
                break;
            case 3317:
                x[i] ^= 2076;
                break;
            case 3318:
                x[i] ^= 1060;
                break;
            case 3319:
                x[i] ^= 1005;
                break;
            case 3320:
                x[i] ^= 1135;
                break;
            case 3321:
                x[i] ^= 1059;
                break;
            case 3322:
                x[i] ^= 2327;
                break;
            case 3323:
                x[i] ^= 149;
                break;
            case 3324:
                x[i] ^= 3987;
                break;
            case 3325:
                x[i] ^= 185;
                break;
            case 3326:
                x[i] ^= 3362;
                break;
            case 3327:
                x[i] ^= 256;
                break;
            case 3328:
                x[i] ^= 4042;
                break;
            case 3329:
                x[i] ^= 3708;
                break;
            case 3330:
                x[i] ^= 760;
                break;
            case 3331:
                x[i] ^= 1202;
                break;
            case 3332:
                x[i] ^= 1769;
                break;
            case 3333:
                x[i] ^= 1694;
                break;
            case 3334:
                x[i] ^= 488;
                break;
            case 3335:
                x[i] ^= 2394;
                break;
            case 3336:
                x[i] ^= 2332;
                break;
            case 3337:
                x[i] ^= 3069;
                break;
            case 3338:
                x[i] ^= 37;
                break;
            case 3339:
                x[i] ^= 887;
                break;
            case 3340:
                x[i] ^= 2779;
                break;
            case 3341:
                x[i] ^= 1417;
                break;
            case 3342:
                x[i] ^= 4089;
                break;
            case 3343:
                x[i] ^= 331;
                break;
            case 3344:
                x[i] ^= 1026;
                break;
            case 3345:
                x[i] ^= 1216;
                break;
            case 3346:
                x[i] ^= 1581;
                break;
            case 3347:
                x[i] ^= 3497;
                break;
            case 3348:
                x[i] ^= 2746;
                break;
            case 3349:
                x[i] ^= 2045;
                break;
            case 3350:
                x[i] ^= 1712;
                break;
            case 3351:
                x[i] ^= 78;
                break;
            case 3352:
                x[i] ^= 3615;
                break;
            case 3353:
                x[i] ^= 1454;
                break;
            case 3354:
                x[i] ^= 1444;
                break;
            case 3355:
                x[i] ^= 3393;
                break;
            case 3356:
                x[i] ^= 1699;
                break;
            case 3357:
                x[i] ^= 2761;
                break;
            case 3358:
                x[i] ^= 621;
                break;
            case 3359:
                x[i] ^= 195;
                break;
            case 3360:
                x[i] ^= 838;
                break;
            case 3361:
                x[i] ^= 2919;
                break;
            case 3362:
                x[i] ^= 820;
                break;
            case 3363:
                x[i] ^= 949;
                break;
            case 3364:
                x[i] ^= 2797;
                break;
            case 3365:
                x[i] ^= 325;
                break;
            case 3366:
                x[i] ^= 2865;
                break;
            case 3367:
                x[i] ^= 3491;
                break;
            case 3368:
                x[i] ^= 213;
                break;
            case 3369:
                x[i] ^= 2491;
                break;
            case 3370:
                x[i] ^= 2286;
                break;
            case 3371:
                x[i] ^= 3182;
                break;
            case 3372:
                x[i] ^= 1534;
                break;
            case 3373:
                x[i] ^= 2630;
                break;
            case 3374:
                x[i] ^= 701;
                break;
            case 3375:
                x[i] ^= 841;
                break;
            case 3376:
                x[i] ^= 3354;
                break;
            case 3377:
                x[i] ^= 1306;
                break;
            case 3378:
                x[i] ^= 1450;
                break;
            case 3379:
                x[i] ^= 783;
                break;
            case 3380:
                x[i] ^= 2581;
                break;
            case 3381:
                x[i] ^= 2071;
                break;
            case 3382:
                x[i] ^= 2252;
                break;
            case 3383:
                x[i] ^= 2597;
                break;
            case 3384:
                x[i] ^= 1498;
                break;
            case 3385:
                x[i] ^= 4065;
                break;
            case 3386:
                x[i] ^= 1234;
                break;
            case 3387:
                x[i] ^= 3035;
                break;
            case 3388:
                x[i] ^= 2989;
                break;
            case 3389:
                x[i] ^= 952;
                break;
            case 3390:
                x[i] ^= 3644;
                break;
            case 3391:
                x[i] ^= 3162;
                break;
            case 3392:
                x[i] ^= 355;
                break;
            case 3393:
                x[i] ^= 71;
                break;
            case 3394:
                x[i] ^= 2643;
                break;
            case 3395:
                x[i] ^= 2355;
                break;
            case 3396:
                x[i] ^= 2728;
                break;
            case 3397:
                x[i] ^= 1137;
                break;
            case 3398:
                x[i] ^= 450;
                break;
            case 3399:
                x[i] ^= 717;
                break;
            case 3400:
                x[i] ^= 3710;
                break;
            case 3401:
                x[i] ^= 1988;
                break;
            case 3402:
                x[i] ^= 230;
                break;
            case 3403:
                x[i] ^= 1473;
                break;
            case 3404:
                x[i] ^= 4019;
                break;
            case 3405:
                x[i] ^= 866;
                break;
            case 3406:
                x[i] ^= 2960;
                break;
            case 3407:
                x[i] ^= 2848;
                break;
            case 3408:
                x[i] ^= 1645;
                break;
            case 3409:
                x[i] ^= 3110;
                break;
            case 3410:
                x[i] ^= 468;
                break;
            case 3411:
                x[i] ^= 64;
                break;
            case 3412:
                x[i] ^= 1953;
                break;
            case 3413:
                x[i] ^= 3604;
                break;
            case 3414:
                x[i] ^= 2037;
                break;
            case 3415:
                x[i] ^= 3896;
                break;
            case 3416:
                x[i] ^= 1920;
                break;
            case 3417:
                x[i] ^= 912;
                break;
            case 3418:
                x[i] ^= 3900;
                break;
            case 3419:
                x[i] ^= 495;
                break;
            case 3420:
                x[i] ^= 2771;
                break;
            case 3421:
                x[i] ^= 115;
                break;
            case 3422:
                x[i] ^= 1377;
                break;
            case 3423:
                x[i] ^= 88;
                break;
            case 3424:
                x[i] ^= 1954;
                break;
            case 3425:
                x[i] ^= 3198;
                break;
            case 3426:
                x[i] ^= 190;
                break;
            case 3427:
                x[i] ^= 2395;
                break;
            case 3428:
                x[i] ^= 2696;
                break;
            case 3429:
                x[i] ^= 1008;
                break;
            case 3430:
                x[i] ^= 2659;
                break;
            case 3431:
                x[i] ^= 1340;
                break;
            case 3432:
                x[i] ^= 1997;
                break;
            case 3433:
                x[i] ^= 531;
                break;
            case 3434:
                x[i] ^= 2149;
                break;
            case 3435:
                x[i] ^= 57;
                break;
            case 3436:
                x[i] ^= 1883;
                break;
            case 3437:
                x[i] ^= 2075;
                break;
            case 3438:
                x[i] ^= 2309;
                break;
            case 3439:
                x[i] ^= 1971;
                break;
            case 3440:
                x[i] ^= 3427;
                break;
            case 3441:
                x[i] ^= 2661;
                break;
            case 3442:
                x[i] ^= 1979;
                break;
            case 3443:
                x[i] ^= 993;
                break;
            case 3444:
                x[i] ^= 2188;
                break;
            case 3445:
                x[i] ^= 39;
                break;
            case 3446:
                x[i] ^= 2920;
                break;
            case 3447:
                x[i] ^= 1475;
                break;
            case 3448:
                x[i] ^= 1578;
                break;
            case 3449:
                x[i] ^= 3200;
                break;
            case 3450:
                x[i] ^= 2993;
                break;
            case 3451:
                x[i] ^= 3962;
                break;
            case 3452:
                x[i] ^= 4050;
                break;
            case 3453:
                x[i] ^= 2977;
                break;
            case 3454:
                x[i] ^= 180;
                break;
            case 3455:
                x[i] ^= 1642;
                break;
            case 3456:
                x[i] ^= 3735;
                break;
            case 3457:
                x[i] ^= 1335;
                break;
            case 3458:
                x[i] ^= 3815;
                break;
            case 3459:
                x[i] ^= 1019;
                break;
            case 3460:
                x[i] ^= 1676;
                break;
            case 3461:
                x[i] ^= 171;
                break;
            case 3462:
                x[i] ^= 3554;
                break;
            case 3463:
                x[i] ^= 1402;
                break;
            case 3464:
                x[i] ^= 3447;
                break;
            case 3465:
                x[i] ^= 2706;
                break;
            case 3466:
                x[i] ^= 2215;
                break;
            case 3467:
                x[i] ^= 589;
                break;
            case 3468:
                x[i] ^= 2966;
                break;
            case 3469:
                x[i] ^= 503;
                break;
            case 3470:
                x[i] ^= 2449;
                break;
            case 3471:
                x[i] ^= 212;
                break;
            case 3472:
                x[i] ^= 2134;
                break;
            case 3473:
                x[i] ^= 1603;
                break;
            case 3474:
                x[i] ^= 1091;
                break;
            case 3475:
                x[i] ^= 3913;
                break;
            case 3476:
                x[i] ^= 351;
                break;
            case 3477:
                x[i] ^= 1412;
                break;
            case 3478:
                x[i] ^= 523;
                break;
            case 3479:
                x[i] ^= 3635;
                break;
            case 3480:
                x[i] ^= 1064;
                break;
            case 3481:
                x[i] ^= 254;
                break;
            case 3482:
                x[i] ^= 1099;
                break;
            case 3483:
                x[i] ^= 1317;
                break;
            case 3484:
                x[i] ^= 3775;
                break;
            case 3485:
                x[i] ^= 2087;
                break;
            case 3486:
                x[i] ^= 2953;
                break;
            case 3487:
                x[i] ^= 758;
                break;
            case 3488:
                x[i] ^= 85;
                break;
            case 3489:
                x[i] ^= 2177;
                break;
            case 3490:
                x[i] ^= 890;
                break;
            case 3491:
                x[i] ^= 4070;
                break;
            case 3492:
                x[i] ^= 679;
                break;
            case 3493:
                x[i] ^= 3790;
                break;
            case 3494:
                x[i] ^= 2729;
                break;
            case 3495:
                x[i] ^= 3240;
                break;
            case 3496:
                x[i] ^= 1401;
                break;
            case 3497:
                x[i] ^= 3234;
                break;
            case 3498:
                x[i] ^= 4023;
                break;
            case 3499:
                x[i] ^= 2694;
                break;
            case 3500:
                x[i] ^= 2438;
                break;
            case 3501:
                x[i] ^= 1262;
                break;
            case 3502:
                x[i] ^= 3235;
                break;
            case 3503:
                x[i] ^= 2566;
                break;
            case 3504:
                x[i] ^= 1461;
                break;
            case 3505:
                x[i] ^= 636;
                break;
            case 3506:
                x[i] ^= 3336;
                break;
            case 3507:
                x[i] ^= 3978;
                break;
            case 3508:
                x[i] ^= 947;
                break;
            case 3509:
                x[i] ^= 2426;
                break;
            case 3510:
                x[i] ^= 2970;
                break;
            case 3511:
                x[i] ^= 3528;
                break;
            case 3512:
                x[i] ^= 893;
                break;
            case 3513:
                x[i] ^= 3237;
                break;
            case 3514:
                x[i] ^= 3737;
                break;
            case 3515:
                x[i] ^= 691;
                break;
            case 3516:
                x[i] ^= 127;
                break;
            case 3517:
                x[i] ^= 1538;
                break;
            case 3518:
                x[i] ^= 3022;
                break;
            case 3519:
                x[i] ^= 498;
                break;
            case 3520:
                x[i] ^= 2546;
                break;
            case 3521:
                x[i] ^= 1836;
                break;
            case 3522:
                x[i] ^= 2330;
                break;
            case 3523:
                x[i] ^= 479;
                break;
            case 3524:
                x[i] ^= 2718;
                break;
            case 3525:
                x[i] ^= 1820;
                break;
            case 3526:
                x[i] ^= 987;
                break;
            case 3527:
                x[i] ^= 1838;
                break;
            case 3528:
                x[i] ^= 897;
                break;
            case 3529:
                x[i] ^= 889;
                break;
            case 3530:
                x[i] ^= 1369;
                break;
            case 3531:
                x[i] ^= 776;
                break;
            case 3532:
                x[i] ^= 103;
                break;
            case 3533:
                x[i] ^= 2621;
                break;
            case 3534:
                x[i] ^= 1432;
                break;
            case 3535:
                x[i] ^= 1741;
                break;
            case 3536:
                x[i] ^= 3038;
                break;
            case 3537:
                x[i] ^= 881;
                break;
            case 3538:
                x[i] ^= 205;
                break;
            case 3539:
                x[i] ^= 3668;
                break;
            case 3540:
                x[i] ^= 2159;
                break;
            case 3541:
                x[i] ^= 945;
                break;
            case 3542:
                x[i] ^= 124;
                break;
            case 3543:
                x[i] ^= 903;
                break;
            case 3544:
                x[i] ^= 59;
                break;
            case 3545:
                x[i] ^= 603;
                break;
            case 3546:
                x[i] ^= 609;
                break;
            case 3547:
                x[i] ^= 2144;
                break;
            case 3548:
                x[i] ^= 4093;
                break;
            case 3549:
                x[i] ^= 2575;
                break;
            case 3550:
                x[i] ^= 2436;
                break;
            case 3551:
                x[i] ^= 1915;
                break;
            case 3552:
                x[i] ^= 4057;
                break;
            case 3553:
                x[i] ^= 3758;
                break;
            case 3554:
                x[i] ^= 1069;
                break;
            case 3555:
                x[i] ^= 305;
                break;
            case 3556:
                x[i] ^= 1842;
                break;
            case 3557:
                x[i] ^= 2958;
                break;
            case 3558:
                x[i] ^= 3249;
                break;
            case 3559:
                x[i] ^= 2024;
                break;
            case 3560:
                x[i] ^= 106;
                break;
            case 3561:
                x[i] ^= 3469;
                break;
            case 3562:
                x[i] ^= 1174;
                break;
            case 3563:
                x[i] ^= 2853;
                break;
            case 3564:
                x[i] ^= 1140;
                break;
            case 3565:
                x[i] ^= 496;
                break;
            case 3566:
                x[i] ^= 3515;
                break;
            case 3567:
                x[i] ^= 364;
                break;
            case 3568:
                x[i] ^= 3641;
                break;
            case 3569:
                x[i] ^= 2601;
                break;
            case 3570:
                x[i] ^= 3973;
                break;
            case 3571:
                x[i] ^= 3047;
                break;
            case 3572:
                x[i] ^= 1177;
                break;
            case 3573:
                x[i] ^= 1598;
                break;
            case 3574:
                x[i] ^= 1621;
                break;
            case 3575:
                x[i] ^= 3972;
                break;
            case 3576:
                x[i] ^= 563;
                break;
            case 3577:
                x[i] ^= 2137;
                break;
            case 3578:
                x[i] ^= 1409;
                break;
            case 3579:
                x[i] ^= 1802;
                break;
            case 3580:
                x[i] ^= 210;
                break;
            case 3581:
                x[i] ^= 497;
                break;
            case 3582:
                x[i] ^= 3694;
                break;
            case 3583:
                x[i] ^= 4059;
                break;
            case 3584:
                x[i] ^= 3761;
                break;
            case 3585:
                x[i] ^= 938;
                break;
            case 3586:
                x[i] ^= 3270;
                break;
            case 3587:
                x[i] ^= 633;
                break;
            case 3588:
                x[i] ^= 2598;
                break;
            case 3589:
                x[i] ^= 3051;
                break;
            case 3590:
                x[i] ^= 933;
                break;
            case 3591:
                x[i] ^= 607;
                break;
            case 3592:
                x[i] ^= 2044;
                break;
            case 3593:
                x[i] ^= 824;
                break;
            case 3594:
                x[i] ^= 651;
                break;
            case 3595:
                x[i] ^= 612;
                break;
            case 3596:
                x[i] ^= 1637;
                break;
            case 3597:
                x[i] ^= 1190;
                break;
            case 3598:
                x[i] ^= 1065;
                break;
            case 3599:
                x[i] ^= 509;
                break;
            case 3600:
                x[i] ^= 2329;
                break;
            case 3601:
                x[i] ^= 899;
                break;
            case 3602:
                x[i] ^= 3341;
                break;
            case 3603:
                x[i] ^= 3539;
                break;
            case 3604:
                x[i] ^= 705;
                break;
            case 3605:
                x[i] ^= 234;
                break;
            case 3606:
                x[i] ^= 1732;
                break;
            case 3607:
                x[i] ^= 1901;
                break;
            case 3608:
                x[i] ^= 2305;
                break;
            case 3609:
                x[i] ^= 1119;
                break;
            case 3610:
                x[i] ^= 907;
                break;
            case 3611:
                x[i] ^= 2264;
                break;
            case 3612:
                x[i] ^= 3421;
                break;
            case 3613:
                x[i] ^= 1443;
                break;
            case 3614:
                x[i] ^= 3048;
                break;
            case 3615:
                x[i] ^= 2994;
                break;
            case 3616:
                x[i] ^= 2914;
                break;
            case 3617:
                x[i] ^= 3865;
                break;
            case 3618:
                x[i] ^= 951;
                break;
            case 3619:
                x[i] ^= 1692;
                break;
            case 3620:
                x[i] ^= 451;
                break;
            case 3621:
                x[i] ^= 3325;
                break;
            case 3622:
                x[i] ^= 1843;
                break;
            case 3623:
                x[i] ^= 3564;
                break;
            case 3624:
                x[i] ^= 1618;
                break;
            case 3625:
                x[i] ^= 2695;
                break;
            case 3626:
                x[i] ^= 2548;
                break;
            case 3627:
                x[i] ^= 1823;
                break;
            case 3628:
                x[i] ^= 2185;
                break;
            case 3629:
                x[i] ^= 2858;
                break;
            case 3630:
                x[i] ^= 3654;
                break;
            case 3631:
                x[i] ^= 1969;
                break;
            case 3632:
                x[i] ^= 2682;
                break;
            case 3633:
                x[i] ^= 1798;
                break;
            case 3634:
                x[i] ^= 1931;
                break;
            case 3635:
                x[i] ^= 3416;
                break;
            case 3636:
                x[i] ^= 928;
                break;
            case 3637:
                x[i] ^= 964;
                break;
            case 3638:
                x[i] ^= 90;
                break;
            case 3639:
                x[i] ^= 2497;
                break;
            case 3640:
                x[i] ^= 1124;
                break;
            case 3641:
                x[i] ^= 2496;
                break;
            case 3642:
                x[i] ^= 1808;
                break;
            case 3643:
                x[i] ^= 2709;
                break;
            case 3644:
                x[i] ^= 2965;
                break;
            case 3645:
                x[i] ^= 3127;
                break;
            case 3646:
                x[i] ^= 1807;
                break;
            case 3647:
                x[i] ^= 3096;
                break;
            case 3648:
                x[i] ^= 3303;
                break;
            case 3649:
                x[i] ^= 3406;
                break;
            case 3650:
                x[i] ^= 3244;
                break;
            case 3651:
                x[i] ^= 3541;
                break;
            case 3652:
                x[i] ^= 3083;
                break;
            case 3653:
                x[i] ^= 2131;
                break;
            case 3654:
                x[i] ^= 3098;
                break;
            case 3655:
                x[i] ^= 1132;
                break;
            case 3656:
                x[i] ^= 2191;
                break;
            case 3657:
                x[i] ^= 3875;
                break;
            case 3658:
                x[i] ^= 3318;
                break;
            case 3659:
                x[i] ^= 729;
                break;
            case 3660:
                x[i] ^= 1345;
                break;
            case 3661:
                x[i] ^= 670;
                break;
            case 3662:
                x[i] ^= 1131;
                break;
            case 3663:
                x[i] ^= 1723;
                break;
            case 3664:
                x[i] ^= 3882;
                break;
            case 3665:
                x[i] ^= 2517;
                break;
            case 3666:
                x[i] ^= 70;
                break;
            case 3667:
                x[i] ^= 1455;
                break;
            case 3668:
                x[i] ^= 3797;
                break;
            case 3669:
                x[i] ^= 605;
                break;
            case 3670:
                x[i] ^= 201;
                break;
            case 3671:
                x[i] ^= 1342;
                break;
            case 3672:
                x[i] ^= 2479;
                break;
            case 3673:
                x[i] ^= 2646;
                break;
            case 3674:
                x[i] ^= 582;
                break;
            case 3675:
                x[i] ^= 3901;
                break;
            case 3676:
                x[i] ^= 1261;
                break;
            case 3677:
                x[i] ^= 3535;
                break;
            case 3678:
                x[i] ^= 3828;
                break;
            case 3679:
                x[i] ^= 3260;
                break;
            case 3680:
                x[i] ^= 2806;
                break;
            case 3681:
                x[i] ^= 3832;
                break;
            case 3682:
                x[i] ^= 3158;
                break;
            case 3683:
                x[i] ^= 1298;
                break;
            case 3684:
                x[i] ^= 2274;
                break;
            case 3685:
                x[i] ^= 1066;
                break;
            case 3686:
                x[i] ^= 743;
                break;
            case 3687:
                x[i] ^= 2099;
                break;
            case 3688:
                x[i] ^= 3946;
                break;
            case 3689:
                x[i] ^= 2675;
                break;
            case 3690:
                x[i] ^= 3659;
                break;
            case 3691:
                x[i] ^= 299;
                break;
            case 3692:
                x[i] ^= 2170;
                break;
            case 3693:
                x[i] ^= 2201;
                break;
            case 3694:
                x[i] ^= 2069;
                break;
            case 3695:
                x[i] ^= 1505;
                break;
            case 3696:
                x[i] ^= 1476;
                break;
            case 3697:
                x[i] ^= 3650;
                break;
            case 3698:
                x[i] ^= 1141;
                break;
            case 3699:
                x[i] ^= 408;
                break;
            case 3700:
                x[i] ^= 940;
                break;
            case 3701:
                x[i] ^= 1895;
                break;
            case 3702:
                x[i] ^= 3705;
                break;
            case 3703:
                x[i] ^= 48;
                break;
            case 3704:
                x[i] ^= 4031;
                break;
            case 3705:
                x[i] ^= 3561;
                break;
            case 3706:
                x[i] ^= 257;
                break;
            case 3707:
                x[i] ^= 3194;
                break;
            case 3708:
                x[i] ^= 1431;
                break;
            case 3709:
                x[i] ^= 335;
                break;
            case 3710:
                x[i] ^= 803;
                break;
            case 3711:
                x[i] ^= 3590;
                break;
            case 3712:
                x[i] ^= 2043;
                break;
            case 3713:
                x[i] ^= 1716;
                break;
            case 3714:
                x[i] ^= 4054;
                break;
            case 3715:
                x[i] ^= 1967;
                break;
            case 3716:
                x[i] ^= 3648;
                break;
            case 3717:
                x[i] ^= 2277;
                break;
            case 3718:
                x[i] ^= 121;
                break;
            case 3719:
                x[i] ^= 2086;
                break;
            case 3720:
                x[i] ^= 2092;
                break;
            case 3721:
                x[i] ^= 2026;
                break;
            case 3722:
                x[i] ^= 3793;
                break;
            case 3723:
                x[i] ^= 788;
                break;
            case 3724:
                x[i] ^= 1162;
                break;
            case 3725:
                x[i] ^= 3299;
                break;
            case 3726:
                x[i] ^= 2852;
                break;
            case 3727:
                x[i] ^= 1508;
                break;
            case 3728:
                x[i] ^= 1860;
                break;
            case 3729:
                x[i] ^= 1717;
                break;
            case 3730:
                x[i] ^= 3642;
                break;
            case 3731:
                x[i] ^= 3267;
                break;
            case 3732:
                x[i] ^= 3776;
                break;
            case 3733:
                x[i] ^= 1271;
                break;
            case 3734:
                x[i] ^= 2824;
                break;
            case 3735:
                x[i] ^= 1163;
                break;
            case 3736:
                x[i] ^= 2454;
                break;
            case 3737:
                x[i] ^= 1392;
                break;
            case 3738:
                x[i] ^= 1744;
                break;
            case 3739:
                x[i] ^= 3819;
                break;
            case 3740:
                x[i] ^= 3938;
                break;
            case 3741:
                x[i] ^= 244;
                break;
            case 3742:
                x[i] ^= 2476;
                break;
            case 3743:
                x[i] ^= 819;
                break;
            case 3744:
                x[i] ^= 538;
                break;
            case 3745:
                x[i] ^= 2483;
                break;
            case 3746:
                x[i] ^= 1265;
                break;
            case 3747:
                x[i] ^= 869;
                break;
            case 3748:
                x[i] ^= 1090;
                break;
            case 3749:
                x[i] ^= 1659;
                break;
            case 3750:
                x[i] ^= 647;
                break;
            case 3751:
                x[i] ^= 3496;
                break;
            case 3752:
                x[i] ^= 2268;
                break;
            case 3753:
                x[i] ^= 2021;
                break;
            case 3754:
                x[i] ^= 173;
                break;
            case 3755:
                x[i] ^= 3609;
                break;
            case 3756:
                x[i] ^= 138;
                break;
            case 3757:
                x[i] ^= 768;
                break;
            case 3758:
                x[i] ^= 2631;
                break;
            case 3759:
                x[i] ^= 2312;
                break;
            case 3760:
                x[i] ^= 2645;
                break;
            case 3761:
                x[i] ^= 1086;
                break;
            case 3762:
                x[i] ^= 1252;
                break;
            case 3763:
                x[i] ^= 1558;
                break;
            case 3764:
                x[i] ^= 2884;
                break;
            case 3765:
                x[i] ^= 916;
                break;
            case 3766:
                x[i] ^= 300;
                break;
            case 3767:
                x[i] ^= 2596;
                break;
            case 3768:
                x[i] ^= 2912;
                break;
            case 3769:
                x[i] ^= 3800;
                break;
            case 3770:
                x[i] ^= 1404;
                break;
            case 3771:
                x[i] ^= 4081;
                break;
            case 3772:
                x[i] ^= 159;
                break;
            case 3773:
                x[i] ^= 3205;
                break;
            case 3774:
                x[i] ^= 2001;
                break;
            case 3775:
                x[i] ^= 1526;
                break;
            case 3776:
                x[i] ^= 2343;
                break;
            case 3777:
                x[i] ^= 3977;
                break;
            case 3778:
                x[i] ^= 1821;
                break;
            case 3779:
                x[i] ^= 2939;
                break;
            case 3780:
                x[i] ^= 1348;
                break;
            case 3781:
                x[i] ^= 1257;
                break;
            case 3782:
                x[i] ^= 2847;
                break;
            case 3783:
                x[i] ^= 1985;
                break;
            case 3784:
                x[i] ^= 1110;
                break;
            case 3785:
                x[i] ^= 2052;
                break;
            case 3786:
                x[i] ^= 3617;
                break;
            case 3787:
                x[i] ^= 532;
                break;
            case 3788:
                x[i] ^= 540;
                break;
            case 3789:
                x[i] ^= 2461;
                break;
            case 3790:
                x[i] ^= 2323;
                break;
            case 3791:
                x[i] ^= 3579;
                break;
            case 3792:
                x[i] ^= 3373;
                break;
            case 3793:
                x[i] ^= 2862;
                break;
            case 3794:
                x[i] ^= 101;
                break;
            case 3795:
                x[i] ^= 1884;
                break;
            case 3796:
                x[i] ^= 4013;
                break;
            case 3797:
                x[i] ^= 1867;
                break;
            case 3798:
                x[i] ^= 1206;
                break;
            case 3799:
                x[i] ^= 3283;
                break;
            case 3800:
                x[i] ^= 3349;
                break;
            case 3801:
                x[i] ^= 3965;
                break;
            case 3802:
                x[i] ^= 1103;
                break;
            case 3803:
                x[i] ^= 2747;
                break;
            case 3804:
                x[i] ^= 822;
                break;
            case 3805:
                x[i] ^= 1818;
                break;
            case 3806:
                x[i] ^= 1926;
                break;
            case 3807:
                x[i] ^= 2935;
                break;
            case 3808:
                x[i] ^= 1812;
                break;
            case 3809:
                x[i] ^= 1548;
                break;
            case 3810:
                x[i] ^= 2034;
                break;
            case 3811:
                x[i] ^= 2703;
                break;
            case 3812:
                x[i] ^= 1175;
                break;
            case 3813:
                x[i] ^= 113;
                break;
            case 3814:
                x[i] ^= 1912;
                break;
            case 3815:
                x[i] ^= 3159;
                break;
            case 3816:
                x[i] ^= 2121;
                break;
            case 3817:
                x[i] ^= 1428;
                break;
            case 3818:
                x[i] ^= 4002;
                break;
            case 3819:
                x[i] ^= 1662;
                break;
            case 3820:
                x[i] ^= 1407;
                break;
            case 3821:
                x[i] ^= 1219;
                break;
            case 3822:
                x[i] ^= 3273;
                break;
            case 3823:
                x[i] ^= 2218;
                break;
            case 3824:
                x[i] ^= 373;
                break;
            case 3825:
                x[i] ^= 2284;
                break;
            case 3826:
                x[i] ^= 3371;
                break;
            case 3827:
                x[i] ^= 3133;
                break;
            case 3828:
                x[i] ^= 82;
                break;
            case 3829:
                x[i] ^= 2280;
                break;
            case 3830:
                x[i] ^= 2160;
                break;
            case 3831:
                x[i] ^= 3215;
                break;
            case 3832:
                x[i] ^= 2093;
                break;
            case 3833:
                x[i] ^= 3383;
                break;
            case 3834:
                x[i] ^= 104;
                break;
            case 3835:
                x[i] ^= 235;
                break;
            case 3836:
                x[i] ^= 2442;
                break;
            case 3837:
                x[i] ^= 4039;
                break;
            case 3838:
                x[i] ^= 2800;
                break;
            case 3839:
                x[i] ^= 3338;
                break;
            case 3840:
                x[i] ^= 1023;
                break;
            case 3841:
                x[i] ^= 2665;
                break;
            case 3842:
                x[i] ^= 2163;
                break;
            case 3843:
                x[i] ^= 282;
                break;
            case 3844:
                x[i] ^= 1312;
                break;
            case 3845:
                x[i] ^= 112;
                break;
            case 3846:
                x[i] ^= 804;
                break;
            case 3847:
                x[i] ^= 3669;
                break;
            case 3848:
                x[i] ^= 854;
                break;
            case 3849:
                x[i] ^= 3295;
                break;
            case 3850:
                x[i] ^= 92;
                break;
            case 3851:
                x[i] ^= 518;
                break;
            case 3852:
                x[i] ^= 456;
                break;
            case 3853:
                x[i] ^= 3880;
                break;
            case 3854:
                x[i] ^= 858;
                break;
            case 3855:
                x[i] ^= 613;
                break;
            case 3856:
                x[i] ^= 429;
                break;
            case 3857:
                x[i] ^= 3034;
                break;
            case 3858:
                x[i] ^= 3455;
                break;
            case 3859:
                x[i] ^= 3367;
                break;
            case 3860:
                x[i] ^= 1082;
                break;
            case 3861:
                x[i] ^= 3684;
                break;
            case 3862:
                x[i] ^= 3151;
                break;
            case 3863:
                x[i] ^= 2805;
                break;
            case 3864:
                x[i] ^= 1270;
                break;
            case 3865:
                x[i] ^= 3957;
                break;
            case 3866:
                x[i] ^= 976;
                break;
            case 3867:
                x[i] ^= 3144;
                break;
            case 3868:
                x[i] ^= 4094;
                break;
            case 3869:
                x[i] ^= 170;
                break;
            case 3870:
                x[i] ^= 81;
                break;
            case 3871:
                x[i] ^= 2830;
                break;
            case 3872:
                x[i] ^= 3285;
                break;
            case 3873:
                x[i] ^= 4014;
                break;
            case 3874:
                x[i] ^= 228;
                break;
            case 3875:
                x[i] ^= 2054;
                break;
            case 3876:
                x[i] ^= 3123;
                break;
            case 3877:
                x[i] ^= 2930;
                break;
            case 3878:
                x[i] ^= 671;
                break;
            case 3879:
                x[i] ^= 426;
                break;
            case 3880:
                x[i] ^= 1349;
                break;
            case 3881:
                x[i] ^= 2811;
                break;
            case 3882:
                x[i] ^= 1164;
                break;
            case 3883:
                x[i] ^= 2214;
                break;
            case 3884:
                x[i] ^= 3726;
                break;
            case 3885:
                x[i] ^= 2590;
                break;
            case 3886:
                x[i] ^= 1077;
                break;
            case 3887:
                x[i] ^= 2377;
                break;
            case 3888:
                x[i] ^= 3843;
                break;
            case 3889:
                x[i] ^= 2967;
                break;
            case 3890:
                x[i] ^= 334;
                break;
            case 3891:
                x[i] ^= 1422;
                break;
            case 3892:
                x[i] ^= 2716;
                break;
            case 3893:
                x[i] ^= 695;
                break;
            case 3894:
                x[i] ^= 1375;
                break;
            case 3895:
                x[i] ^= 1899;
                break;
            case 3896:
                x[i] ^= 3574;
                break;
            case 3897:
                x[i] ^= 1751;
                break;
            case 3898:
                x[i] ^= 1943;
                break;
            case 3899:
                x[i] ^= 1359;
                break;
            case 3900:
                x[i] ^= 2389;
                break;
            case 3901:
                x[i] ^= 790;
                break;
            case 3902:
                x[i] ^= 3459;
                break;
            case 3903:
                x[i] ^= 1844;
                break;
            case 3904:
                x[i] ^= 1117;
                break;
            case 3905:
                x[i] ^= 3236;
                break;
            case 3906:
                x[i] ^= 2910;
                break;
            case 3907:
                x[i] ^= 2542;
                break;
            case 3908:
                x[i] ^= 1158;
                break;
            case 3909:
                x[i] ^= 2296;
                break;
            case 3910:
                x[i] ^= 455;
                break;
            case 3911:
                x[i] ^= 199;
                break;
            case 3912:
                x[i] ^= 3405;
                break;
            case 3913:
                x[i] ^= 1058;
                break;
            case 3914:
                x[i] ^= 3925;
                break;
            case 3915:
                x[i] ^= 1665;
                break;
            case 3916:
                x[i] ^= 3185;
                break;
            case 3917:
                x[i] ^= 35;
                break;
            case 3918:
                x[i] ^= 1391;
                break;
            case 3919:
                x[i] ^= 811;
                break;
            case 3920:
                x[i] ^= 847;
                break;
            case 3921:
                x[i] ^= 182;
                break;
            case 3922:
                x[i] ^= 2108;
                break;
            case 3923:
                x[i] ^= 1185;
                break;
            case 3924:
                x[i] ^= 3837;
                break;
            case 3925:
                x[i] ^= 356;
                break;
            case 3926:
                x[i] ^= 3833;
                break;
            case 3927:
                x[i] ^= 2297;
                break;
            case 3928:
                x[i] ^= 2155;
                break;
            case 3929:
                x[i] ^= 1852;
                break;
            case 3930:
                x[i] ^= 2647;
                break;
            case 3931:
                x[i] ^= 860;
                break;
            case 3932:
                x[i] ^= 466;
                break;
            case 3933:
                x[i] ^= 120;
                break;
            case 3934:
                x[i] ^= 4007;
                break;
            case 3935:
                x[i] ^= 3294;
                break;
            case 3936:
                x[i] ^= 1237;
                break;
            case 3937:
                x[i] ^= 274;
                break;
            case 3938:
                x[i] ^= 2961;
                break;
            case 3939:
                x[i] ^= 3552;
                break;
            case 3940:
                x[i] ^= 3271;
                break;
            case 3941:
                x[i] ^= 1399;
                break;
            case 3942:
                x[i] ^= 813;
                break;
            case 3943:
                x[i] ^= 4071;
                break;
            case 3944:
                x[i] ^= 1361;
                break;
            case 3945:
                x[i] ^= 884;
                break;
            case 3946:
                x[i] ^= 494;
                break;
            case 3947:
                x[i] ^= 1875;
                break;
            case 3948:
                x[i] ^= 714;
                break;
            case 3949:
                x[i] ^= 3808;
                break;
            case 3950:
                x[i] ^= 117;
                break;
            case 3951:
                x[i] ^= 3093;
                break;
            case 3952:
                x[i] ^= 447;
                break;
            case 3953:
                x[i] ^= 2457;
                break;
            case 3954:
                x[i] ^= 2161;
                break;
            case 3955:
                x[i] ^= 3985;
                break;
            case 3956:
                x[i] ^= 3612;
                break;
            case 3957:
                x[i] ^= 2842;
                break;
            case 3958:
                x[i] ^= 2562;
                break;
            case 3959:
                x[i] ^= 580;
                break;
            case 3960:
                x[i] ^= 3893;
                break;
            case 3961:
                x[i] ^= 9;
                break;
            case 3962:
                x[i] ^= 2315;
                break;
            case 3963:
                x[i] ^= 646;
                break;
            case 3964:
                x[i] ^= 402;
                break;
            case 3965:
                x[i] ^= 2608;
                break;
            case 3966:
                x[i] ^= 3959;
                break;
            case 3967:
                x[i] ^= 3187;
                break;
            case 3968:
                x[i] ^= 2335;
                break;
            case 3969:
                x[i] ^= 2419;
                break;
            case 3970:
                x[i] ^= 1780;
                break;
            case 3971:
                x[i] ^= 2881;
                break;
            case 3972:
                x[i] ^= 3942;
                break;
            case 3973:
                x[i] ^= 2809;
                break;
            case 3974:
                x[i] ^= 733;
                break;
            case 3975:
                x[i] ^= 233;
                break;
            case 3976:
                x[i] ^= 3679;
                break;
            case 3977:
                x[i] ^= 2742;
                break;
            case 3978:
                x[i] ^= 3956;
                break;
            case 3979:
                x[i] ^= 755;
                break;
            case 3980:
                x[i] ^= 513;
                break;
            case 3981:
                x[i] ^= 1123;
                break;
            case 3982:
                x[i] ^= 1235;
                break;
            case 3983:
                x[i] ^= 2680;
                break;
            case 3984:
                x[i] ^= 1790;
                break;
            case 3985:
                x[i] ^= 75;
                break;
            case 3986:
                x[i] ^= 3226;
                break;
            case 3987:
                x[i] ^= 2626;
                break;
            case 3988:
                x[i] ^= 2632;
                break;
            case 3989:
                x[i] ^= 1680;
                break;
            case 3990:
                x[i] ^= 1354;
                break;
            case 3991:
                x[i] ^= 3581;
                break;
            case 3992:
                x[i] ^= 2276;
                break;
            case 3993:
                x[i] ^= 3907;
                break;
            case 3994:
                x[i] ^= 1370;
                break;
            case 3995:
                x[i] ^= 2042;
                break;
            case 3996:
                x[i] ^= 2322;
                break;
            case 3997:
                x[i] ^= 1664;
                break;
            case 3998:
                x[i] ^= 2174;
                break;
            case 3999:
                x[i] ^= 2843;
                break;
            case 4000:
                x[i] ^= 1136;
                break;
            case 4001:
                x[i] ^= 1161;
                break;
            case 4002:
                x[i] ^= 1862;
                break;
            case 4003:
                x[i] ^= 1372;
                break;
            case 4004:
                x[i] ^= 3731;
                break;
            case 4005:
                x[i] ^= 1745;
                break;
            case 4006:
                x[i] ^= 2157;
                break;
            case 4007:
                x[i] ^= 535;
                break;
            case 4008:
                x[i] ^= 3961;
                break;
            case 4009:
                x[i] ^= 2056;
                break;
            case 4010:
                x[i] ^= 6;
                break;
            case 4011:
                x[i] ^= 1465;
                break;
            case 4012:
                x[i] ^= 2334;
                break;
            case 4013:
                x[i] ^= 2987;
                break;
            case 4014:
                x[i] ^= 1933;
                break;
            case 4015:
                x[i] ^= 443;
                break;
            case 4016:
                x[i] ^= 547;
                break;
            case 4017:
                x[i] ^= 1648;
                break;
            case 4018:
                x[i] ^= 3452;
                break;
            case 4019:
                x[i] ^= 1080;
                break;
            case 4020:
                x[i] ^= 2422;
                break;
            case 4021:
                x[i] ^= 2988;
                break;
            case 4022:
                x[i] ^= 851;
                break;
            case 4023:
                x[i] ^= 54;
                break;
            case 4024:
                x[i] ^= 873;
                break;
            case 4025:
                x[i] ^= 3933;
                break;
            case 4026:
                x[i] ^= 3864;
                break;
            case 4027:
                x[i] ^= 659;
                break;
            case 4028:
                x[i] ^= 2306;
                break;
            case 4029:
                x[i] ^= 1495;
                break;
            case 4030:
                x[i] ^= 3755;
                break;
            case 4031:
                x[i] ^= 1376;
                break;
            case 4032:
                x[i] ^= 2952;
                break;
            case 4033:
                x[i] ^= 846;
                break;
            case 4034:
                x[i] ^= 2385;
                break;
            case 4035:
                x[i] ^= 68;
                break;
            case 4036:
                x[i] ^= 2067;
                break;
            case 4037:
                x[i] ^= 2376;
                break;
            case 4038:
                x[i] ^= 1344;
                break;
            case 4039:
                x[i] ^= 196;
                break;
            case 4040:
                x[i] ^= 3643;
                break;
            case 4041:
                x[i] ^= 2412;
                break;
            case 4042:
                x[i] ^= 2117;
                break;
            case 4043:
                x[i] ^= 954;
                break;
            case 4044:
                x[i] ^= 762;
                break;
            case 4045:
                x[i] ^= 176;
                break;
            case 4046:
                x[i] ^= 977;
                break;
            case 4047:
                x[i] ^= 1514;
                break;
            case 4048:
                x[i] ^= 1582;
                break;
            case 4049:
                x[i] ^= 2009;
                break;
            case 4050:
                x[i] ^= 4046;
                break;
            case 4051:
                x[i] ^= 3376;
                break;
            case 4052:
                x[i] ^= 2002;
                break;
            case 4053:
                x[i] ^= 3952;
                break;
            case 4054:
                x[i] ^= 3209;
                break;
            case 4055:
                x[i] ^= 1828;
                break;
            case 4056:
                x[i] ^= 3071;
                break;
            case 4057:
                x[i] ^= 3676;
                break;
            case 4058:
                x[i] ^= 1479;
                break;
            case 4059:
                x[i] ^= 3739;
                break;
            case 4060:
                x[i] ^= 3626;
                break;
            case 4061:
                x[i] ^= 3012;
                break;
            case 4062:
                x[i] ^= 2690;
                break;
            case 4063:
                x[i] ^= 3786;
                break;
            case 4064:
                x[i] ^= 1561;
                break;
            case 4065:
                x[i] ^= 3288;
                break;
            case 4066:
                x[i] ^= 457;
                break;
            case 4067:
                x[i] ^= 163;
                break;
            case 4068:
                x[i] ^= 3888;
                break;
            case 4069:
                x[i] ^= 2932;
                break;
            case 4070:
                x[i] ^= 1628;
                break;
            case 4071:
                x[i] ^= 470;
                break;
            case 4072:
                x[i] ^= 2568;
                break;
            case 4073:
                x[i] ^= 791;
                break;
            case 4074:
                x[i] ^= 415;
                break;
            case 4075:
                x[i] ^= 825;
                break;
            case 4076:
                x[i] ^= 502;
                break;
            case 4077:
                x[i] ^= 3319;
                break;
            case 4078:
                x[i] ^= 2796;
                break;
            case 4079:
                x[i] ^= 910;
                break;
            case 4080:
                x[i] ^= 983;
                break;
            case 4081:
                x[i] ^= 3753;
                break;
            case 4082:
                x[i] ^= 1330;
                break;
            case 4083:
                x[i] ^= 3652;
                break;
            case 4084:
                x[i] ^= 2267;
                break;
            case 4085:
                x[i] ^= 4010;
                break;
            case 4086:
                x[i] ^= 2555;
                break;
            case 4087:
                x[i] ^= 3689;
                break;
            case 4088:
                x[i] ^= 3382;
                break;
            case 4089:
                x[i] ^= 3919;
                break;
            case 4090:
                x[i] ^= 2205;
                break;
            case 4091:
                x[i] ^= 635;
                break;
            case 4092:
                x[i] ^= 3663;
                break;
            case 4093:
                x[i] ^= 444;
                break;
            case 4094:
                x[i] ^= 2246;
                break;
            case 4095:
                x[i] ^= 3392;
                break;
            }
        }
    }
    bench_end();

    printf("[switch] finished");
    BLACK_BOX(x);
    free(x);
}
