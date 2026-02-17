// Language switcher — toggles between /ja/ and /en/ preserving the current page
(function() {
    var path = window.location.pathname;
    var targetPath = path.replace('/ja/', '/en/');

    var switcher = document.createElement('a');
    switcher.href = targetPath;
    switcher.className = 'lang-switcher';
    switcher.textContent = 'English';
    switcher.title = 'Switch to English';

    var rightButtons = document.querySelector('.right-buttons');
    if (rightButtons) {
        rightButtons.insertBefore(switcher, rightButtons.firstChild);
    }
})();
