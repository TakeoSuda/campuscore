
document.addEventListener('DOMContentLoaded', () => {
  const form = document.getElementById('upload-form');
  const submitBtn = document.getElementById('submit-btn');
  const loadingSpinner = document.getElementById('loading-spinner');

  if (form) {
    form.addEventListener('submit', () => {
      // 1. ボタンを無効化して連打を防ぐ
      submitBtn.disabled = true;
      submitBtn.style.opacity = '0.5';
      submitBtn.value = '送信中...';

      // 2. ぐるぐるアニメーションとメッセージを表示
      loadingSpinner.style.display = 'block';
    });
  }
});
