# Mobile Remote

Phản chiếu và điều khiển điện thoại Android từ macOS qua cáp USB (chế độ USB debugging). Phản chiếu màn hình iPhone / iPad qua cáp USB (chỉ xem).

Phía điện thoại chạy `scrcpy-server` v4.1 (Apache-2.0, ghim cứng phiên bản). Phía Mac là client viết bằng Swift.

## Trạng thái

- [x] Giai đoạn 0: nói chuyện với adb, chạy server, đọc luồng video v4.1, giải mã thử bằng VideoToolbox
- [ ] Giai đoạn 1: app hiển thị màn hình — đã chạy ổn định 57–60 fps; còn thiếu kiểm tra xoay màn hình và đo độ trễ
- [ ] Giai đoạn 2: điều khiển bằng chuột — chạm, kéo, cuộn, phím điều hướng đã kiểm chứng trên máy thật qua `mrctl`; thao tác chuột trong cửa sổ app cần thử bằng tay
- [x] Cửa sổ Home liệt kê thiết bị (mở, hiện, ngắt từng máy) và chép ảnh màn hình vào clipboard
- [x] Giao diện Liquid Glass, logo và icon app, đóng gói thành `Mobile Remote.app`
- [x] iPhone / iPad: phản chiếu màn hình qua USB (thiết bị screen-capture của CoreMediaIO); điều khiển qua WebDriverAgent (chạm, vuốt, cuộn, Home, âm lượng, khóa) — cần cài WDA một lần bằng `scripts/install-wda.sh`
- [ ] Giai đoạn 3: bàn phím, clipboard, tự kết nối khi cắm máy
- [x] Ghi màn hình ra MP4 (Android: chép thẳng luồng H.264/H.265, không nén lại; iPhone: nén HEVC phần cứng)
- [ ] Giai đoạn 4: âm thanh, kéo thả file
- [ ] Giai đoạn 5: đóng gói, ký và notarize

## Cấu trúc

| Thư mục | Nội dung |
|---|---|
| `Sources/ADBKit` | Client cho giao thức smart-socket của adb server (`tcp:5037`): liệt kê và theo dõi thiết bị, shell, push, mở socket trên máy |
| `Sources/ScrcpyKit` | Khởi chạy server, tách luồng video v4.x, mã hóa lệnh điều khiển, chuột ảo UHID |
| `Sources/VideoKit` | Annex B → AVCC, tạo format description, giải mã bằng VideoToolbox |
| `Sources/AppleDeviceKit` | iPhone / iPad: phát hiện máy cắm USB qua CoreMediaIO và thu màn hình bằng AVCaptureSession |
| `Sources/MirrorKit` | Pipeline của một phiên phản chiếu: chạy server, đọc luồng trên luồng riêng, đẩy khung hình vào lớp hiển thị |
| `Sources/MobileRemote` | App: cửa sổ Home (SwiftUI) liệt kê thiết bị, mỗi máy một cửa sổ phản chiếu (AppKit) |
| `Sources/mrctl` | Công cụ dòng lệnh để thử toàn bộ chuỗi mà không cần app |
| `tools/bench` | Script Python đo CPU, RAM, fps và thời gian khởi động của server trên điện thoại |

## Yêu cầu

- macOS 14 trở lên, Xcode 16 trở lên
- `adb` (Android SDK Platform-Tools). Nếu adb server chưa chạy, công cụ tự tìm `adb` qua `ADB_PATH`, `ANDROID_HOME`, `~/Library/Android/sdk` hoặc `PATH`
- Điện thoại Android 5.0 trở lên, đã bật USB debugging và đã chấp nhận máy Mac

## Build và chạy thử

```sh
swift build
swift test

.build/debug/mrctl devices
.build/debug/mrctl watch
.build/debug/mrctl stream --seconds 10 --max-size 1280
.build/debug/mrctl stream --seconds 10 --record clip.mp4    # ghi luồng Android ra MP4
.build/debug/mrctl snapshot --codec h265 -o snapshot.png
.build/debug/mrctl screencap -o screencap.png        # ảnh PNG gốc do điện thoại tự chụp

# Gửi thao tác qua đúng bộ dịch chuột của app (tọa độ tính theo pixel video)
.build/debug/mrctl tap --at 540,1280
.build/debug/mrctl swipe --from 540,1500 --to 540,1100 --ms 800
.build/debug/mrctl scroll --at 540,1300 --dy -3
.build/debug/mrctl key --name back
```

Chạy `mrctl` không kèm tham số để xem đầy đủ tùy chọn.

Chạy app (mặc định H.265, cạnh dài 1600 px, 60 fps; tự lùi về H.264 nếu máy không có bộ nén HEVC):

```sh
swift run MobileRemote
swift run MobileRemote --stats                      # in fps và Mbps mỗi giây
swift run MobileRemote --codec h264 --max-size 1280
swift run MobileRemote --open SERIAL                # mở thẳng một máy, bất kể tùy chọn tự động mở
```

Sau một đợt chuyển động, bộ nén của điện thoại có thể để lại khung hình cuối bị mờ rồi chỉ gửi khung rỗng, khiến hình mờ mãi cho tới lần thay đổi kế tiếp. App tự nhận ra tình huống này và xin một khung hình chính mới (`RESET_VIDEO`). Cờ `--no-settle-refresh` tắt cơ chế đó để so sánh.

## Đóng gói thành app

```sh
scripts/build-app.sh             # tạo dist/Mobile Remote.app
scripts/build-app.sh --install   # tạo rồi chép vào /Applications
```

Script build bản release, tạo icon từ `Sources/MobileRemote/Resources/AppLogo.png`, ghi `Info.plist` và ký ad-hoc. Chữ ký này đủ để chạy trên chính máy build. Muốn phát cho máy khác thì cần ký Developer ID và notarize (giai đoạn 5). Tên app, bundle id và phiên bản nằm ở đầu script.

Giao diện dùng Liquid Glass trên macOS 26. Trên macOS 14 và 15, các thành phần kính tự chuyển sang vật liệu mờ thông thường.

## Điều khiển trong cửa sổ app

| Thao tác trên Mac | Kết quả trên điện thoại |
|---|---|
| Chuột trái: bấm, giữ, kéo | Chạm, nhấn giữ, vuốt |
| Cuộn bằng bánh xe hoặc hai ngón trên trackpad | Cuộn nội dung |
| Chuột phải | Back (bật màn hình nếu đang tắt) |
| Chuột giữa | Home |
| Nút chuột thứ 4 / thứ 5 | Đa nhiệm / mở bảng thông báo |
| Dải nút bên phải màn hình | Back, Home, Đa nhiệm, âm lượng, nguồn |
| Nút máy ảnh hoặc ⌃⌘C | Chép ảnh màn hình vào clipboard: PNG độ phân giải gốc, không qua nén video |
| Nút ghi hoặc ⌃⌘R | Bắt đầu / dừng ghi màn hình. File MP4 lưu vào `~/Movies/Mobile Remote/`, tên theo máy và thời điểm; menu Thiết bị › Mở thư mục ghi hình |

Ghi hình không có âm thanh. Với Android, luồng video từ điện thoại được chép nguyên vào file (codec và độ phân giải đúng như đang phản chiếu, gần như không tốn CPU); ghi bắt đầu ở khung hình chính kế tiếp (app xin ngay, khoảng 0,2–1 giây) và tự dừng nếu màn hình đổi kích thước (xoay). Với iPhone, khung hình thô được nén HEVC phần cứng ở độ phân giải gốc, khoảng 12 Mbps.

Cửa sổ Home (⌘0) liệt kê mọi thiết bị adb, kể cả máy ảo và máy nối qua mạng. Tùy chọn “Tự động mở khi cắm máy qua USB” mặc định bật; tắt đi nếu muốn tự chọn máy để mở.

## iPhone / iPad

iOS đưa màn hình của máy cắm USB tới Mac dưới dạng một thiết bị video (cùng cơ chế QuickTime › Ghi phim mới dùng), nên app phản chiếu được iPhone mà không cần cài gì lên máy. Yêu cầu:

- iPhone đã bấm “Tin cậy” máy Mac và **đang mở khóa** (máy khóa thì không có hình).
- App được cấp quyền Camera (macOS xếp thiết bị này vào nhóm camera).
- Khi đang phản chiếu, iOS chuyển âm thanh của điện thoại sang Mac; app chưa phát âm thanh đó.

### Điều khiển iPhone

Kết nối video không có kênh nhập liệu, nên điều khiển đi qua **WebDriverAgent**: một XCUITest chạy nền trên iPhone, nhận cử chỉ qua HTTP (cổng 8100, app nối tới qua usbmuxd, không cần mạng). Cài một lần cho mỗi máy:

```sh
TEAM=<team id Apple Development> scripts/install-wda.sh [UDID]
```

Yêu cầu: Xcode đã đăng nhập Apple ID, iPhone bật Developer Mode và đang mở khóa. Sau lần cài đầu, trên iPhone vào Cài đặt › Cài đặt chung › VPN & Quản lý thiết bị và bấm Tin cậy nhà phát triển, nếu không runner sẽ bị từ chối với lỗi "Not authorized for performing UI testing actions". Tài khoản miễn phí thì hồ sơ ký hết hạn sau 7 ngày, phải chạy lại script.

Runner chỉ có quyền điều khiển khi chạy trong phiên kiểm thử của Xcode, nên mỗi khi mở cửa sổ iPhone, app chạy `xcodebuild test-without-building` với file `.xctestrun` trong `~/Library/Caches/mobile-remote/wda/build/Build/Products/` (đặt biến `MOBILE_REMOTE_WDA_XCTESTRUN` để chỉ file khác). Điều khiển sẵn sàng sau khoảng 15 giây; đóng cửa sổ thì phiên kiểm thử và runner tắt theo. Log ở `~/Library/Caches/mobile-remote/wda/wda-<UDID>.log`.

Khác với Android, một cử chỉ được gửi trọn gói khi thả chuột (WebDriverAgent phát lại với đúng tốc độ kéo), nên không có phản hồi trực tiếp trong lúc kéo; đo trên iPhone XS Max sau khi tinh chỉnh (tắt chờ idle và tắt chụp cây accessibility qua `appium/settings`): chạm 0,4 giây, Home 0,5 giây, cuộn 0,6 giây, kéo 300 ms mất 0,8–1,0 giây. Mỗi điểm trung gian của một cú kéo có chi phí riêng (trước tinh chỉnh 0,45 giây, 49 điểm mất 31 giây), nên app rút mỗi cú kéo về tối đa 4 đoạn và gom các nấc cuộn bánh xe trong 150 ms thành một cú vuốt. Chạm dứt khoát và kéo bằng một chuyển động thì hợp nhất. Chuột phải là Home. Không mở được Control Center và App Switcher (giới hạn của XCUITest). iOS 27 có dịch vụ HID chính thức qua CoreDevice, có thể thay WebDriverAgent sau này.

```sh
.build/debug/mrctl ios                          # liệt kê iPhone / iPad đang cắm
.build/debug/mrctl ios -o iphone.png --seconds 5   # thu 5 giây rồi lưu khung hình cuối
.build/debug/mrctl ios -o iphone.png --seconds 5 --record clip.mp4
.build/debug/mrctl wda --button home               # WebDriverAgent đang chạy? bấm Home
.build/debug/mrctl wda --swipe 350,500,60,500      # vuốt (tọa độ tính bằng điểm)
```

## Nâng phiên bản scrcpy-server

Giao thức giữa client và server là giao thức nội bộ của scrcpy và thay đổi giữa các bản (v4.0 đã đổi định dạng luồng video). Khi nâng phiên bản:

1. Thay file trong `Sources/ScrcpyKit/Resources/` và tên resource trong `Package.swift`.
2. Cập nhật cả ba hằng số trong `ScrcpyProtocol.swift` (phiên bản, tên file, sha256 lấy từ `SHA256SUMS.txt` của bản phát hành).
3. Đối chiếu `doc/develop.md` và `app/tests/test_control_msg_serialize.c` ở tag mới với `StreamDemuxer.swift`, `ControlMessage.swift` và các test tương ứng.

## Giấy phép bên thứ ba

`scrcpy-server` © Genymobile / Romain Vimont, giấy phép Apache-2.0: <https://github.com/Genymobile/scrcpy>
