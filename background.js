// 툴바 아이콘을 누르면 문제 편집 페이지를 연다.
chrome.action.onClicked.addListener(() => chrome.runtime.openOptionsPage());
